// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Foundation
import SwiftUI
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message:message) }
}
final class FixtureBacking: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?
  func read() -> Data? { lock.withLock { bytes } }
  func write(_ data: Data) { lock.withLock { bytes = data } }
  func replace(_ data: Data?) { lock.withLock { bytes = data } }
}
@MainActor final class ImportTestApp: NSObject, NSApplicationDelegate {
  let backing = FixtureBacking()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-import-ui-"+UUID().uuidString)
  var store: NativePreferencesStore!
  var service: NativeDefaultsImportService!
  var availability: DefaultsImportAvailability!
  var paths: NativeImportPaths!
  var controller: DefaultsImportWindowController?
  var reversed = false, quitting = false
  var newConnections = 0
  private var task: Task<Void,Never>?
  private let source = Data("TidyVNC Configuration file Version 1.0\nServerName=private-fixture.invalid\nPassword=private-secret-fixture\nSecurityTypes=None\nShared=on\nSendClipboard=off\nScalingFactor=125\nFullScreenMode=Selected\nFullScreenSelectedMonitors=2\n".utf8)
  var snapshot: NativeDisplaySnapshot {
    let names = reversed ? ["Fixture Right","Fixture Left"] : ["Fixture Left","Fixture Right"]
    return NativeDisplaySnapshot(generation:reversed ? 2 : 1,displays:names.enumerated().map { index,name in
      let rect = NativeDisplayRectangle(x:Double(index*1000),y:0,width:1000,height:800)
      return NativeDisplay(id:.init(name),name:name,bounds:rect,workArea:rect,backingScale:1,isPrimary:index == 0)
    },error:nil)
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      paths = try NativeImportPaths(homeDirectory:root.path,environment:[:])
      for url in [paths.currentDefaults,paths.legacyDefaults[0]] {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try source.write(to:url)
      }
      store = NativePreferencesStore(backing:backing)
      service = NativeDefaultsImportService(paths:paths,store:store)
      availability = DefaultsImportAvailability(store:store)
      showImport()
      NSApp.activate(ignoringOtherApps:true)
      if CommandLine.arguments.contains("--verify") {
        task = Task { @MainActor in
          do {
            try await verify()
            // Run as a native run-loop event, like a menu action. Calling
            // deferred AppKit termination from a Swift job or a dispatch block
            // can prevent its nested loop from servicing our shutdown task.
            NSApp.perform(#selector(NSApplication.terminate(_:)),with:nil,afterDelay:0)
          }
          catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
      }
    } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
  }
  @objc func showImport() {
    if let controller { controller.showWindow(nil); return }
    controller = DefaultsImportWindowController(service:service,displays:{ [weak self] in self!.snapshot },
      openConnection:{ [weak self] in self?.newConnections += 1 },onClosed:{ [weak self] closed in
        if self?.controller === closed { self?.controller = nil }
      })
    controller?.showWindow(nil)
  }
  @objc func changeDisplays() { reversed.toggle() }
  @objc func resetFixture() {
    Task { @MainActor in
      await controller?.shutdown(); backing.replace(nil); reversed = false
      try? source.write(to:paths.currentDefaults)
      availability.refresh(); showImport()
    }
  }
  @objc func legacyFixture() {
    Task { @MainActor in
      await controller?.shutdown(); backing.replace(nil); reversed = false
      try? FileManager.default.removeItem(at:paths.currentDefaults)
      availability.refresh(); showImport()
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting { return .terminateNow }
    quitting = true
    report("termination requested")
    Task { @MainActor in
      await controller?.shutdown(); report("termination window drained")
      await availability?.close(); report("termination availability drained")
      await store?.close()
      try? FileManager.default.removeItem(at:root)
      NSApp.reply(toApplicationShouldTerminate:true)
    }
    return .terminateLater
  }
  func report(_ text: String) { FileHandle.standardError.write(Data((text+"\n").utf8)) }
  func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
    throw Failure(message:"Import UI fixture timed out")
  }
  func render(_ name: String, dark: Bool = false, minimum: Bool = false, scrollToEnd: Bool = false) async throws {
    guard let window = controller?.window, let view = window.contentView,
          let index = CommandLine.arguments.firstIndex(of:"--output"), index+1 < CommandLine.arguments.count else { throw Failure(message:"missing render context") }
    try check(abs(window.contentMinSize.width-640) < 1 && abs(window.contentMinSize.height-572) < 1,
      "defaults import minimum survives hosting: \(window.contentMinSize)")
    let originalSize = view.bounds.size
    if minimum { window.setContentSize(window.contentMinSize) }
    defer { if minimum { window.setContentSize(originalSize) } }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
    view.appearance = window.appearance
    view.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(100)); view.layoutSubtreeIfNeeded()
    guard let fitting = controller?.contentSizeThatFits(view.bounds.size) else { throw Failure(message:"missing content") }
    try check(fitting.width <= view.bounds.width && fitting.height <= view.bounds.height,"import content \(fitting) fits window \(view.bounds.size)")
    if scrollToEnd {
      func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
      }
      guard let scroll = scrollViews(view).first, let document = scroll.documentView else {
        throw Failure(message:"missing defaults details scroller")
      }
      document.scroll(NSPoint(x:0,y:document.bounds.maxY)); scroll.reflectScrolledClipView(scroll.contentView)
      if document.bounds.height > scroll.contentView.bounds.height+1 {
        try check(scroll.contentView.bounds.origin.y > 0,"remaining defaults details reachable by scrolling")
      }
    }
    window.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"missing bitmap") }
    view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
    guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw Failure(message:"missing PNG") }
    try bytes.write(to:directory.appendingPathComponent(name+".png"))
  }
  func renderOffer() async throws {
    guard let index = CommandLine.arguments.firstIndex(of:"--output"), index+1 < CommandLine.arguments.count else {
      throw Failure(message:"missing offer render path")
    }
    let host = NSHostingController(rootView:FirstUseDefaultsImportOffer(availability:availability,open:{})
      .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
      .background(Color(nsColor:.windowBackgroundColor)))
    host.sizingOptions = []
    let size = NSSize(width:592,height:160)
    let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentViewController = host; window.setContentSize(size)
    defer { window.close(); window.contentViewController = nil }
    let view = host.view
    for dark in [false,true] {
      window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua); view.appearance = window.appearance
      view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for:.milliseconds(60))
      let fitting = host.sizeThatFits(in:size)
      try check(fitting.width <= size.width && fitting.height <= size.height,"first-use offer fits connection content width")
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"missing offer bitmap") }
      view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
      let output = URL(fileURLWithPath:CommandLine.arguments[index+1]).appendingPathComponent(dark ? "first-use-dark.png" : "first-use-light.png")
      try bitmap.representation(using:.png,properties:[:])!.write(to:output)
    }
  }
  func verify() async throws {
    try await until { availability.canOffer }
    try await render("choices")
    try await render("choices-minimum",minimum:true)
    try await renderOffer()
    let state = controller!.state
    let order = try snapshot.documentMonitorOrder()
    _ = state.begin(origin:.currentXDG,legacyDisplays:order)
    try await until { state.review != nil }
    let cancelled = state.review!.id
    state.cancel(cancelled)
    try check(backing.read() == nil,"review cancellation writes nothing")
    _ = state.begin(origin:.currentXDG,legacyDisplays:order)
    try await until { state.review != nil }
    try await render("review-light"); try await render("review-dark",dark:true)
    try await render("review-minimum",minimum:true)
    try await render("review-minimum-end",minimum:true,scrollToEnd:true)
    let review = state.review!
    state.approve(cancelled,acknowledging:Set(review.proposal.notices.map(\.line)),currentDisplays:order)
    try check(state.review?.id == review.id,"stale UI approval ignored")
    state.approve(review.id,acknowledging:Set(review.proposal.notices.map(\.line)),currentDisplays:Array(order.reversed()))
    try await until { !state.hasPending }
    try check(state.issue != nil && backing.read() == nil,"display change fails before native write")
    try await render("changed-displays")
    try await render("changed-displays-minimum",minimum:true)
    _ = state.begin(origin:.currentXDG,legacyDisplays:order)
    try await until { state.review != nil }
    let accepted = state.review!
    state.approve(accepted.id,acknowledging:Set(accepted.proposal.notices.map(\.line)),currentDisplays:order)
    try await until { state.imported != nil && !availability.canOffer }
    try check(state.imported?.values.security == nil && state.imported?.values.shared == true,"review imports ordinary values only")
    try check(try Data(contentsOf:paths.currentDefaults) == source,"original source untouched")
    try await render("success")
    try await render("success-minimum",minimum:true)
    report("rendered successful import")
    let old = controller!
    await old.shutdown()
    report("closed first presentation")
    try check(controller == nil && old.isClosing && old.window?.isVisible == false && !old.state.hasPending,"closing drains exact presentation")
    showImport()
    try check(controller!.state !== old.state,"reopen owns a fresh state")
    _ = controller!.state.begin(origin:.currentXDG,legacyDisplays:order)
    try await until { !controller!.state.hasPending }
    try check(controller!.state.issue != nil,"existing native state wins in reopened UI")
    try await render("native-state-error-minimum",minimum:true)
    await controller?.shutdown()
    report("closed second presentation")
    backing.replace(nil); availability.refresh(); try await until { availability.canOffer }
    backing.replace(Data("malformed-native".utf8)); availability.refresh()
    try await until { !availability.canOffer }
    backing.replace(nil); availability.refresh(); try await until { availability.canOffer }
    availability.dismiss(); try check(availability.dismissed,"first-use offer can be dismissed for this launch")
    try FileManager.default.removeItem(at:paths.currentDefaults)
    showImport()
    let legacy = controller!.state
    _ = legacy.begin(origin:.currentXDG,legacyDisplays:order)
    try await until { !legacy.hasPending }
    try check(legacy.foundNoSource && legacy.review == nil,"current choice cannot silently import legacy")
    try await render("missing-source-minimum",minimum:true)
    _ = legacy.begin(origin:.legacy,legacyDisplays:order)
    try await until { legacy.review != nil }
    let candidate = legacy.review!
    legacy.approve(candidate.id,acknowledging:Set(candidate.proposal.notices.map(\.line)),currentDisplays:order)
    try await until { legacy.imported != nil }
    report("legacy imported")
    try check(legacy.imported?.importedFrom == .legacy,"legacy requires its separate choice")
    print("PASS native import presentation, first-use eligibility, immutable review, topology, source isolation and close/reopen")
  }
}
@main struct NativeImportUITests {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = ImportTestApp(); app.delegate = delegate
    let menu = NSMenu(), application = NSMenuItem(), file = NSMenuItem()
    let appMenu = NSMenu(), fileMenu = NSMenu(title:"Fixture")
    let quit = NSMenuItem(title:"Quit Import UI Tests",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    quit.target = app; appMenu.addItem(quit); application.submenu = appMenu; menu.addItem(application)
    for (name,selector) in [("Import Connection Defaults…",#selector(ImportTestApp.showImport)),
                            ("Reset Fixture",#selector(ImportTestApp.resetFixture)),
                            ("Use Legacy Fixture",#selector(ImportTestApp.legacyFixture)),
                            ("Change Display Order",#selector(ImportTestApp.changeDisplays))] {
      let item = NSMenuItem(title:name,action:selector,keyEquivalent:""); item.target = delegate; fileMenu.addItem(item)
    }
    file.submenu = fileMenu; menu.addItem(file); app.mainMenu = menu
    withExtendedLifetime(delegate) { app.run() }
  }
}
