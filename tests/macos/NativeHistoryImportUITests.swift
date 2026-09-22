// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message:message) }
}
final class FixtureBacking: NativeProfileHistoryBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?
  func read() -> Data? { lock.withLock { bytes } }
  func replace(_ data: Data, expected: Data?) throws {
    try lock.withLock {
      guard bytes == expected else { throw NativeStorageError.conflict }
      bytes = data
    }
  }
  func reset(_ data: Data? = nil) { lock.withLock { bytes = data } }
}
actor DelayedService: NativeHistoryImportServing {
  let review: NativeHistoryImportReview
  let store: NativeProfileHistoryStore
  var delayRead = true, delayWrite = false
  var waiting: CheckedContinuation<Void,Never>?
  var readError: NativeDocumentOpenError?
  init(store: NativeProfileHistoryStore) throws {
    self.store = store
    review = NativeHistoryImportReview(source:URL(fileURLWithPath:"/fixture/history"),
      proposal:try NativeHistoryImport(data:Data("fixture.invalid\n".utf8),origin:.currentXDG),expectedRevision:nil)
  }
  func prepare(origin: NativeImportOrigin) async throws -> NativeHistoryImportReview? {
    if delayRead { await withCheckedContinuation { waiting = $0 } }
    if let readError { throw readError }
    return review // Deliberately ignores cancellation to test the owner.
  }
  func commit(_ review: NativeHistoryImportReview, acknowledgingOmissions: Bool) async throws -> NativeProfileHistorySnapshot {
    // Acceptance occurs before the delay, so closing cannot claim rollback.
    let result = try await store.importHistory(review.proposal,expected:review.expectedRevision,
      acknowledgingOmissions:acknowledgingOmissions)
    if delayWrite { await withCheckedContinuation { waiting = $0 } }
    return result
  }
  func configure(read: Bool = false, write: Bool = false, error: NativeDocumentOpenError? = nil) {
    delayRead = read; delayWrite = write; readError = error
  }
  func isWaiting() -> Bool { waiting != nil }
  func release() { waiting?.resume(); waiting = nil }
}

@MainActor final class HistoryImportTestApp: NSObject, NSApplicationDelegate {
  let backing = FixtureBacking()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-history-ui-"+UUID().uuidString)
  var store: NativeProfileHistoryStore!
  var history: NativeRecentHistory!
  var service: NativeHistoryImportService!
  var paths: NativeImportPaths!
  var controller: HistoryImportWindowController?
  var quitting = false
  private var task: Task<Void,Never>?
  private let source = Data(((0..<23).map { "fixture-\($0).invalid:1" } + ["fixture-0.invalid:1"]).joined(separator:"\n").utf8)
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      paths = try NativeImportPaths(homeDirectory:root.path,environment:[:])
      for url in [paths.currentHistory,paths.legacyHistory[0]] {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try source.write(to:url)
      }
      store = NativeProfileHistoryStore(backing:backing)
      history = NativeRecentHistory(store:store); history.reload()
      service = NativeHistoryImportService(paths:paths,store:store)
      showImport(); NSApp.activate(ignoringOtherApps:true)
      if CommandLine.arguments.contains("--verify") {
        task = Task { @MainActor in
          do {
            try await verify()
            NSApp.perform(#selector(NSApplication.terminate(_:)),with:nil,afterDelay:0)
          } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
      }
    } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
  }
  @objc func showImport() {
    if let controller { controller.showWindow(nil); return }
    controller = HistoryImportWindowController(service:service,reloadHistory:{ [history] in history?.reload() },
      onClosed:{ [weak self] closed in
        if self?.controller === closed { self?.controller = nil; self?.history.reload() }
      })
    controller?.showWindow(nil)
  }
  @objc func resetFixture() {
    Task { @MainActor in
      await controller?.shutdown(); backing.reset(); try? source.write(to:paths.currentHistory)
      history.reload(); showImport()
    }
  }
  @objc func legacyFixture() {
    Task { @MainActor in
      await controller?.shutdown(); backing.reset(); try? FileManager.default.removeItem(at:paths.currentHistory)
      history.reload(); showImport()
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting { return .terminateNow }
    quitting = true
    Task { @MainActor in
      await controller?.shutdown(); await history.close(); await store.close()
      try? FileManager.default.removeItem(at:root)
      NSApp.reply(toApplicationShouldTerminate:true)
    }
    return .terminateLater
  }
  func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
    throw Failure(message:"History UI fixture timed out")
  }
  func gate(_ service: DelayedService) async throws {
    for _ in 0..<2000 { if await service.isWaiting() { return }; try await Task.sleep(for:.milliseconds(2)) }
    throw Failure(message:"Service gate timed out")
  }
  func render(_ name: String, dark: Bool = false, minimum: Bool = false) async throws {
    guard let window = controller?.window, let view = window.contentView,
          let index = CommandLine.arguments.firstIndex(of:"--output"), index+1 < CommandLine.arguments.count else { throw Failure(message:"missing render context") }
    try check(window.contentMinSize.width >= 640 && window.contentMinSize.height >= 572,"host preserves import content minimum")
    let originalSize = view.bounds.size
    if minimum {
      let content = window.contentRect(forFrameRect:NSRect(origin:.zero,size:window.minSize)).size
      window.setContentSize(content)
    }
    defer { if minimum { window.setContentSize(originalSize) } }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
    view.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(100)); view.layoutSubtreeIfNeeded()
    guard let fitting = controller?.contentSizeThatFits(view.bounds.size) else { throw Failure(message:"missing content") }
    window.displayIfNeeded()
    print("RENDER \(name): minimum \(window.minSize), fitting \(fitting), bounds \(view.bounds.size)")
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"missing bitmap") }
    view.cacheDisplay(in:view.bounds,to:bitmap)
    guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw Failure(message:"missing PNG") }
    try bytes.write(to:directory.appendingPathComponent(name+".png"))
    try check(fitting.width <= view.bounds.width && fitting.height <= view.bounds.height,"history \(name) fits: \(fitting) within \(view.bounds.size)")
  }
  func verifyLifetimes() async throws {
    let memory = FixtureBacking(), destination = NativeProfileHistoryStore(backing:memory)
    let delayed = try DelayedService(store:destination)
    let state = NativeHistoryImportState(service:delayed)
    let request = state.begin(origin:.currentXDG)!
    try await gate(delayed)
    state.cancel(request)
    try check(state.hasPending && state.begin(origin:.legacy) == nil,"cancelled IO drains before another request")
    await delayed.release(); try await until { !state.hasPending }
    try check(state.review == nil && state.issue == nil && memory.read() == nil,"late read cannot revive review")
    await delayed.configure(error:.notRegular)
    state.begin(origin:.currentXDG); try await until { !state.hasPending }
    try check(state.issue == String(localized:"history.import.the.history.source.must.be.a.regular.file", defaultValue:"The history source must be a regular file."),"history-specific controlled reader failure")
    await delayed.configure(error:.cancelled)
    state.begin(origin:.currentXDG); try await until { !state.hasPending }
    try check(state.issue == nil,"reader cancellation is silent")
    await delayed.configure(write:true)
    state.begin(origin:.currentXDG); try await until { state.review != nil }
    state.approve(state.review!.id,acknowledgingOmissions:false)
    try await gate(delayed)
    state.stop()
    let drain = Task { await state.close() }
    try check(state.hasPending && state.begin(origin:.legacy) == nil,"close keeps IO retained and revokes callbacks")
    await delayed.release(); await drain.value
    try check(state.imported == nil && !state.hasPending && memory.read() != nil,"accepted commit drains without rollback claim or closed delivery")
    await destination.close()
  }
  func verify() async throws {
    try await verifyLifetimes()
    try await until { history.canImportHistory }
    history.dismissImportOffer()
    try check(history.importOfferDismissed && history.canImportHistory,"dismissal hides offer without blocking explicit import")
    try await render("choices")
    try await render("choices-minimum",minimum:true)
    let state = controller!.state
    state.begin(origin:.currentXDG); try await until { state.review != nil }
    let cancelled = state.review!.id; state.cancel(cancelled)
    try check(backing.read() == nil,"cancel review writes nothing")
    state.begin(origin:.currentXDG); try await until { state.review != nil }
    let first = state.review!
    state.approve(cancelled,acknowledgingOmissions:true)
    try check(state.review?.id == first.id,"old preview cannot approve current list")
    state.approve(first.id,acknowledgingOmissions:false)
    try check(state.review?.id == first.id && state.issue != nil && backing.read() == nil,"omission acknowledgement required")
    try await render("review-light"); try await render("review-dark",dark:true)
    try await render("review-minimum",minimum:true)
    // A separate native history operation invalidates the captured destination.
    _ = try await store.clearHistory(expected:nil)
    state.approve(first.id,acknowledgingOmissions:true)
    try await until { !state.hasPending }
    try check(state.imported == nil && state.issue != nil,"intervening native clear rejects stale review")
    try await render("conflict")
    backing.reset()
    state.begin(origin:.currentXDG); try await until { state.review != nil }
    let accepted = state.review!
    state.approve(accepted.id,acknowledgingOmissions:true)
    try await until { state.imported != nil && history.endpoints.count == 20 && !history.canImportHistory }
    try check(history.endpoints == accepted.proposal.endpoints,"successful UI commit refreshes shared recent list in source order")
    try check(try Data(contentsOf:paths.currentHistory) == source,"original history untouched")
    try await render("success")
    let old = controller!; await old.shutdown()
    try check(controller == nil && old.isClosing && !old.state.hasPending,"close drains presentation")
    showImport()
    try check(controller!.state !== old.state,"reopen creates fresh owner")
    controller!.state.begin(origin:.currentXDG)
    try await until { !controller!.state.hasPending }
    try check(controller!.state.issue == NativeHistoryImportError.nativeHistoryExists.description,"repeat import blocked")
    await controller?.shutdown()
    backing.reset(Data("corrupt".utf8)); history.reload(); try await until { !history.isBusy }
    try check(!history.canImportHistory,"corrupt native state cannot offer import")
    backing.reset(); history.reload(); try await until { history.canImportHistory }
    showImport()
    let legacy = controller!.state
    legacy.begin(origin:.legacy); try await until { !legacy.hasPending }
    try check(legacy.issue == NativeHistoryImportError.currentHistoryExists.description,"current history blocks legacy choice")
    try FileManager.default.removeItem(at:paths.currentHistory)
    legacy.begin(origin:.currentXDG); try await until { !legacy.hasPending }
    try check(legacy.foundNoSource,"current absence never silently imports legacy")
    legacy.begin(origin:.legacy); try await until { legacy.review != nil }
    legacy.approve(legacy.review!.id,acknowledgingOmissions:true)
    try await until { legacy.imported != nil && history.endpoints.count == 20 }
    try check(legacy.imported?.historyImportOrigin == .legacy,"separately chosen legacy origin")
    await controller?.shutdown(); backing.reset(); try Data().write(to:paths.currentHistory)
    showImport(); controller!.state.begin(origin:.currentXDG)
    try await until { controller!.state.review != nil }
    try check(controller!.state.review!.proposal.endpoints.isEmpty,"empty source review")
    try await render("empty")
    print("PASS history UI, separate source consent, omission review, recent refresh, stale callbacks, cancellation and close")
  }
}
@main struct NativeHistoryImportUITests {
  @MainActor static func main() {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = HistoryImportTestApp(); app.delegate = delegate
    let menu = NSMenu(), application = NSMenuItem(), file = NSMenuItem()
    let appMenu = NSMenu(), fileMenu = NSMenu(title:"Fixture")
    let quit = NSMenuItem(title:"Quit History Import UI Tests",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    quit.target = app; appMenu.addItem(quit); application.submenu = appMenu; menu.addItem(application)
    for (name,selector) in [("Import Recent Connections…",#selector(HistoryImportTestApp.showImport)),
                            ("Reset Fixture",#selector(HistoryImportTestApp.resetFixture)),
                            ("Use Legacy Fixture",#selector(HistoryImportTestApp.legacyFixture))] {
      let item = NSMenuItem(title:name,action:selector,keyEquivalent:""); item.target = delegate; fileMenu.addItem(item)
    }
    file.submenu = fileMenu; menu.addItem(file); app.mainMenu = menu
    withExtendedLifetime(delegate) { app.run() }
  }
}
