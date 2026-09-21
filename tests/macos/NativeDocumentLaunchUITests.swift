// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import TidyVNCNative

struct Failure: Error { let message: String }
@MainActor final class LaunchCoordinator: NSObject, NSApplicationDelegate, ObservableObject {
  let router = NativeDocumentLaunchRouter()
  var windows: [String:NSWindow] = [:]
  var received: [UUID:URL] = [:]
  private var task: Task<Void,Never>?
  override init() {
    super.init()
    // Exercise the same pre-scene queue needed by a cold Finder event.
    precondition(router.route(filePaths:["/cold-one.tidyvnc","/cold-two.tidyvnc"]))
  }
  func register(_ window: NSWindow, request: NativeDocumentOpenRequest?) {
    let key = request?.id.uuidString ?? "initial"
    windows[key] = window
    if let request { received[request.id] = request.url }
  }
  func install(_ action: OpenWindowAction) {
    router.install { action(id:"document",value:$0) }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    task = Task { @MainActor in
      do {
        try await until { self.received.count == 2 && self.windows.count == 3 }
        let old = Array(self.windows.values)
        guard old.allSatisfy(\.isVisible) else { throw Failure(message:"cold windows not visible") }
        for window in old { window.close() }
        try await until { old.allSatisfy { !$0.isVisible } }
        // No observation/activation helper reopens an app window in this test.
        guard NSApp.windows.filter(\.isVisible).isEmpty else { throw Failure(message:"visible window remains before warm event") }
        let accepted = router.route(filePaths:["/warm-one.tidyvnc","/warm-two.tidyvnc"])
        guard accepted else { throw Failure(message:"warm event rejected") }
        try await until { self.received.count == 4 && NSApp.windows.filter(\.isVisible).count == 2 }
        guard old.allSatisfy({ !$0.isVisible }), Set(received.values.map(\.path)) == Set([
          "/cold-one.tidyvnc","/cold-two.tidyvnc","/warm-one.tidyvnc","/warm-two.tidyvnc"])
        else { throw Failure(message:"warm event reused old window or lost a request") }
        guard router.route(filePaths:["/warm-one.tidyvnc"]) else { throw Failure(message:"repeat event rejected") }
        try await until { self.received.count == 5 && NSApp.windows.filter(\.isVisible).count == 3 }
        router.stop()
        for window in Array(windows.values) { window.close() }
        print("SwiftUI cold queue, zero-window warm delivery and repeated file windows passed")
        NSApp.terminate(nil)
      } catch {
        FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
        exit(1)
      }
    }
  }
  func until(_ condition: () -> Bool) async throws {
    for _ in 0..<5000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
    throw Failure(message:"window lifecycle timed out")
  }
}
struct LaunchWindow: View {
  let coordinator: LaunchCoordinator
  let request: NativeDocumentOpenRequest?
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Text(request?.url.lastPathComponent ?? "Launch test")
      .frame(width:320,height:160)
      .background(Capture(coordinator:coordinator,request:request))
      .onAppear { coordinator.install(openWindow) }
  }
  struct Capture: NSViewRepresentable {
    let coordinator: LaunchCoordinator
    let request: NativeDocumentOpenRequest?
    func makeNSView(context: Context) -> Attachment { Attachment(coordinator:coordinator,request:request) }
    func updateNSView(_ view: Attachment, context: Context) {}
    final class Attachment: NSView {
      weak var coordinator: LaunchCoordinator?
      let request: NativeDocumentOpenRequest?
      init(coordinator: LaunchCoordinator, request: NativeDocumentOpenRequest?) {
        self.coordinator = coordinator; self.request = request; super.init(frame:.zero)
      }
      required init?(coder: NSCoder) { nil }
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { coordinator?.register(window,request:request) }
      }
    }
  }
}
@main struct NativeDocumentLaunchUITests: App {
  @NSApplicationDelegateAdaptor(LaunchCoordinator.self) private var coordinator
  var body: some Scene {
    WindowGroup("Launch test",id:"initial") { LaunchWindow(coordinator:coordinator,request:nil) }
    WindowGroup("Document test",id:"document",for:NativeDocumentOpenRequest.self) { $request in
      if let request { LaunchWindow(coordinator:coordinator,request:request) }
    }
  }
}
