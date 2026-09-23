// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
final class Memory: NativePreferencesBacking, @unchecked Sendable {
  func read() -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message:"launch fixture must not write preferences") }
}
@MainActor enum LaunchContext {
  static var startup = NativeInvocationStartup()
  static var peer: UnsafeMutableRawPointer?
  static var file: URL?
}
@MainActor final class LaunchCoordinator: NSObject, NSApplicationDelegate, ObservableObject {
  let runtime = try! NativeRuntime()
  let store = NativePreferencesStore(backing:Memory())
  var models: [ConnectionModel] = []
  var windows: [ObjectIdentifier:NSWindow] = [:]
  var open: OpenWindowAction?
  private var task: Task<Void,Never>?
  private var argumentFileEvents = 0
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    argumentFileEvents += filenames.count; sender.reply(toOpenOrPrint:.failure)
  }
  func application(_ sender: NSApplication, open urls: [URL]) {
    argumentFileEvents += urls.count; sender.reply(toOpenOrPrint:.failure)
  }
  func make() -> ConnectionModel {
    let launch = LaunchContext.startup.take()
    let model = ConnectionModel(runtime:runtime,preferences:store,document:launch?.document,
      invocation:launch?.invocation,connectOnReady:launch?.connectsOnReady == true) { _,_ in }
    models.append(model)
    return model
  }
  func register(_ window: NSWindow, model: ConnectionModel) {
    windows[ObjectIdentifier(model)] = window
    model.fullscreen.windowStartup.attach(window)
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    task = Task { @MainActor in
      do {
        try await until("first window") { self.models.count == 1 && self.windows.count == 1 && self.open != nil }
        try check(argumentFileEvents == 0,"CLI operands must not become AppKit file events")
        let first = models[0]
        if LaunchContext.file != nil {
          try await until("file review") { first.defaults?.documentReview != nil }
          try check(first.session == nil,"file launch requires review before session admission")
          first.defaults!.acceptDocument(first.defaults!.documentReview!.id)
          try await until("reviewed file") { first.defaults?.isReady == true }
          try check(first.session?.snapshot.state == .idle && first.session?.initialShared == false,
                    "file overrides CLI and stays idle after review")
        } else {
          try await until("automatic connection") { first.session?.snapshot.state == .connected && !first.busy }
          try check(native_test_peer_shared(LaunchContext.peer) == 1,"first window receives CLI connection policy")
        }
        try check(first.defaults?.invocationRequest != nil,"startup request reaches the first window")
        let content = windows[ObjectIdentifier(first)]!.contentRect(forFrameRect:windows[ObjectIdentifier(first)]!.frame)
        try check(abs(content.width-620) < 1 && abs(content.height-420) < 1 && first.fullscreen.windowStartup.resolved,
                  "first SwiftUI window applies CLI content size once after admission")
        open!(id:"connection")
        try await until("second window") { self.models.count == 2 && self.windows.count == 2 && self.models[1].defaults?.isReady == true }
        try checkDefault(models[1])
        try check(models[0] === first,"view updates preserve first connection ownership")
        let old = Array(windows.values)
        for model in models { await model.close() }
        for window in old { window.close() }
        try await until("zero windows") { NSApp.windows.allSatisfy { !$0.isVisible } }
        open!(id:"connection")
        try await until("warm window") { self.models.count == 3 && self.windows.count == 3 && self.models[2].defaults?.isReady == true }
        try checkDefault(models[2])
        try check(old.allSatisfy { !$0.isVisible },"warm launch does not reuse closed windows")
        await models[2].close()
        LaunchContext.startup.stop()
        try await runtime.shutdown(); await store.close()
        for window in Array(windows.values) { window.close() }
        if let peer = LaunchContext.peer { native_test_peer_destroy(peer); LaunchContext.peer = nil }
        if let file = LaunchContext.file { try FileManager.default.removeItem(at:file) }
        print("First-window CLI ownership, file review, independent new windows and zero-window reopening passed")
        NSApp.perform(#selector(NSApplication.terminate(_:)),with:nil,afterDelay:0)
      } catch {
        FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1)
      }
    }
  }
  func checkDefault(_ model: ConnectionModel) throws {
    try check(model.defaults?.invocationRequest == nil && model.defaults?.documentRequest == nil &&
              model.endpoint.isEmpty && model.session?.snapshot.state == .idle && model.session?.initialShared == false && model.session?.initialWindowStartupPolicy == .builtIn,
              "subsequent window inherits native defaults without replaying CLI or file")
  }
  func until(_ label: String, _ condition: () -> Bool) async throws {
    for _ in 0..<5000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
    throw Failure(message:"window lifecycle timed out: "+label)
  }
}
struct LaunchWindow: View {
  let coordinator: LaunchCoordinator
  @StateObject private var model: ConnectionModel
  @Environment(\.openWindow) private var openWindow
  init(coordinator: LaunchCoordinator) {
    self.coordinator = coordinator
    _model = StateObject(wrappedValue:coordinator.make())
  }
  var body: some View {
    Text(model.endpoint.isEmpty ? "Launch fixture" : "Connection fixture")
      .frame(minWidth:320,maxWidth:.infinity,minHeight:160,maxHeight:.infinity)
      .background(Capture(coordinator:coordinator,model:model))
      .onAppear { coordinator.open = openWindow }
  }
  struct Capture: NSViewRepresentable {
    let coordinator: LaunchCoordinator
    let model: ConnectionModel
    func makeNSView(context: Context) -> Attachment { Attachment(coordinator:coordinator,model:model) }
    func updateNSView(_ view: Attachment, context: Context) {}
    final class Attachment: NSView {
      weak var coordinator: LaunchCoordinator?
      let model: ConnectionModel
      init(coordinator: LaunchCoordinator, model: ConnectionModel) {
        self.coordinator = coordinator; self.model = model; super.init(frame:.zero)
      }
      required init?(coder: NSCoder) { nil }
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { coordinator?.register(window,model:model) }
      }
    }
  }
}
struct LaunchApp: App {
  @NSApplicationDelegateAdaptor(LaunchCoordinator.self) private var coordinator
  var body: some Scene {
    WindowGroup("Invocation launch test",id:"connection") { LaunchWindow(coordinator:coordinator) }
  }
}
@main enum NativeInvocationLaunchUITests {
  @MainActor static func main() throws {
    var arguments = try NativeInvocationArguments.read(argc:CommandLine.argc,argv:CommandLine.unsafeArgv)
    // Keep a real operand in process argv so AppKit can expose duplicate parsing.
    // Replace only the parsed copy with the owned fixture's ephemeral destination.
    let fileMode = ProcessInfo.processInfo.environment["TIDYVNC_LAUNCH_FIXTURE_FILE"] == "1"
    try check(arguments.last == (fileMode ? "./fixture.tidyvnc" : "fixture.invalid"),"real process operand supplied")
    arguments.removeLast()
    if fileMode {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-launch-"+UUID().uuidString+".tidyvnc")
      try Data("TidyVNC Configuration file Version 1.0\nServerName=fixture.invalid\nShared=off\n".utf8).write(to:file)
      LaunchContext.file = file; arguments.append(file.path)
    } else {
      guard let peer = native_test_peer_create_pattern(0) else { throw Failure(message:"local peer unavailable") }
      LaunchContext.peer = peer; arguments.append("127.0.0.1::\(native_test_peer_port(peer))")
    }
    arguments.insert(contentsOf:["-geometry=620x420+40+70","-Maximize=off"],at:0)
    let options = try NativeInvocationOptions(arguments:arguments)
    let launch = try NativeInvocationBootstrap.launch(options,workingDirectory:FileManager.default.currentDirectoryPath)
    LaunchContext.startup = NativeInvocationStartup(launch)
    // Do not depend on the host's Cocoa defaults or a previous fixture launch.
    UserDefaults.standard.setVolatileDomain(["NSTreatUnknownArgumentsAsOpen":true,"fixturePreserved":7],forName:UserDefaults.argumentDomain)
    NativeInvocationBootstrap.prepareAppKit()
    try check(!UserDefaults.standard.bool(forKey:"NSTreatUnknownArgumentsAsOpen") &&
      UserDefaults.standard.integer(forKey:"fixturePreserved") == 7,"process-only AppKit handoff preserves other launch defaults")
    LaunchApp.main()
  }
}
