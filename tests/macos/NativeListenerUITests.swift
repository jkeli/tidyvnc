// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine
import Foundation
import SwiftUI
import NativeTestSupport
@testable import TidyVNCNative
struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool,_ message: String) throws { if try !value() { throw Failure(message:message) } }
@MainActor func until(_ label: String,_ condition: () -> Bool) async throws {
  for _ in 0..<3000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Listener UI timeout: "+label)
}
final class Preferences: NativePreferencesBacking, Sendable {
  let data: Data
  init() throws {
    data = try JSONSerialization.data(withJSONObject:["schema":11,"revision":UUID().uuidString,
      "values":["security":["types":"None,VncAuth"],"shared":true,"clipboardSend":false,"reconnectOnError":true]])
  }
  func read() -> Data? { data }
  func write(_ data: Data) throws { throw Failure(message:"Unexpected preferences write") }
}
final class Peer: @unchecked Sendable {
  let raw: UnsafeMutableRawPointer
  init(port: UInt32, authentication: Bool = false) throws {
    guard let raw = native_test_peer_create_reverse(UInt16(port),authentication ? 1 : 0) else { throw Failure(message:"Reverse peer failed") }
    self.raw = raw
  }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor func render(_ controller: ListenerWindowController,_ name: String) async throws {
  let root = URL(fileURLWithPath:"/tmp/tidyvnc-listen-ui-images")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  guard let window = controller.window, let view = window.contentView else { throw Failure(message:"Missing listener window") }
  window.setContentSize(NSSize(width:700,height:560)); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
  try await Task.sleep(for:.milliseconds(60))
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"Missing image") }
  view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
  try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(name+".png"))
}
@MainActor func verify() async throws {
  let runtime = try NativeRuntime(), store = NativePreferencesStore(backing:try Preferences())
  var models: [ConnectionModel] = []
  let listener = ListenerModel(runtime:runtime) { request in
    let model = ConnectionModel(runtime:runtime,preferences:store,reverse:request) { _,_ in }
    models.append(model); return true
  }
  var released = false
  let controller = ListenerWindowController(model:listener) { _ in released = true }
  try check(controller.window!.contentLayoutRect.width >= 660 && controller.window!.contentLayoutRect.height >= 500,
    "hosting controller installation preserves the initial window size")
  controller.showWindow(nil)
  try await render(controller,"idle")
  listener.port = "65536"; listener.start()
  try check(listener.issue != nil && listener.phase == .idle,"port validation before opening sockets")
  listener.port = "0"; listener.ipv4 = false; listener.ipv6 = false; listener.start()
  try check(listener.issue != nil && listener.phase == .idle,"one address family required")
  listener.ipv4 = true; listener.start(); listener.stop()
  try await until("stop during start") { listener.phase == .stopped }
  try check(listener.addresses.isEmpty,"stopped launch never publishes a late listener")
  listener.start(); try await until("listening") { listener.phase == .listening }
  let port = listener.addresses[0].port
  let first = try Peer(port:port), second = try Peer(port:port,authentication:true)
  defer { withExtendedLifetime((first,second)) {} }
  try await until("two incoming") { listener.incoming.count == 2 }
  try await render(controller,"incoming")
  let a = listener.incoming[0], b = listener.incoming[1]
  listener.accept(a); listener.accept(a)
  try check(models.count == 1,"one window reservation per peer")
  listener.accept(b); try check(models.count == 2,"separate window for second incoming peer")
  try await until("connected and authentication") { models.contains { $0.session?.snapshot.state == .connected } && models.contains { $0.session?.prompt != nil } }
  let authenticated = models.first { $0.session?.prompt != nil }!, session = authenticated.session!
  try check(authenticated.isReverse && !authenticated.credentials.supportsRemembering && authenticated.history == nil,"reverse persistence unavailable")
  try check(!authenticated.canExportDocument,"incoming source is not exported as an outbound destination")
  let prompt = session.prompt!
  var user: [UInt8] = [], password = Array("password".utf8)
  try authenticated.credentials.submit(prompt,username:&user,password:&password)
  try await until("both connected") { models.allSatisfy { $0.session?.snapshot.state == .connected && !$0.busy } }
  try check(models.allSatisfy { $0.session?.clipboardSendEnabled == false },"native defaults resolved before incoming handoff")
  try check(native_test_peer_shared(first.raw) == 1 && native_test_peer_shared(second.raw) == 1,"sharing policy reaches both reverse handshakes")
  let conflict = ListenerModel(runtime:runtime) { _ in false }; conflict.port = String(port); conflict.ipv6 = false
  conflict.start(); try await until("bind conflict") { conflict.phase == .failed }
  try check(conflict.issue != nil,"bind failure recovery notice")
  await conflict.close()
  listener.stop(); try await until("stop") { listener.phase == .stopped }
  try check(models.allSatisfy { $0.session?.snapshot.state == .connected },"stopping leaves accepted windows connected")
  try await render(controller,"stopped")
  for model in models { model.disconnect() }
  try await until("disconnected") { models.allSatisfy { $0.session?.snapshot.state == .closed && !$0.busy } }
  for model in models {
    try check(!model.canConnect,"reverse never becomes outbound reconnect to source port")
    let generation = model.session!.generation; model.connect()
    try check(model.session!.generation == generation,"programmatic Connect cannot reconnect reverse source")
    await model.close()
  }
  models.removeAll(); listener.start(); try await until("restart") { listener.phase == .listening }
  let third = try Peer(port:listener.addresses[0].port)
  defer { withExtendedLifetime(third) {} }
  try await until("pending close") { listener.incoming.count == 1 }
  let pending = listener.incoming[0]
  listener.accept(pending); models[0].requestClose()
  await models[0].close()
  try await until("cancel before defaults") { listener.incoming.isEmpty }
  try check(models[0].session == nil || models[0].session!.isClosing,"window close revokes pre-admission request")
  controller.window?.performClose(nil); await controller.shutdown()
  try check(released && controller.isClosing && listener.closing,"window close drains listener owner")
  try await runtime.shutdown(); await store.close()
}
@MainActor final class OpenGate { var enabled = false }
actor LaunchFileReader: NativePasswordFileReading {
  private(set) var calls = 0
  func read(_ url: URL) throws -> NativeCredentialSecret {
    calls += 1; throw NativePasswordFileIssue.unreadable
  }
}
@MainActor func verifyLaunch() async throws {
  let runtime = try NativeRuntime(), store = NativePreferencesStore(backing:try Preferences())
  var launch = try NativeInvocationBootstrap.launch(.init(arguments:["-listen","-UseIPv6=off",
    "-Shared=off","-SendClipboard=on","-SecurityTypes=VncAuth","-passwd=unused-file","0"]),workingDirectory:"/launch")
  var username: [UInt8]?, password: [UInt8]? = Array("password".utf8)
  let captured = try NativeLaunchCredentialInputs(username:&username,password:&password,
    passwordFile:URL(fileURLWithPath:"/private-fixture/unused-file"))
  launch.credentials = captured
  let startup = NativeInvocationStartup(launch), request = startup.take()!
  try check(startup.take() == nil && !request.connectsOnReady,"listen consumes one launch request without outbound auto-connect")
  var models: [ConnectionModel] = []
  let gate = OpenGate(), reader = LaunchFileReader()
  let listener = ListenerModel(runtime:runtime,launch:request) { reverse in
    guard gate.enabled else { return false }
    models.append(ConnectionModel(runtime:runtime,preferences:store,reverse:reverse,passwordFileReader:reader) { _,_ in }); return true
  }
  try check(listener.phase == .idle && listener.port == "0" && listener.ipv4 && !listener.ipv6,"CLI config installed before scene appearance")
  listener.startLaunchIfNeeded(); listener.startLaunchIfNeeded()
  try await until("CLI listening") { listener.phase == .listening }
  try check(listener.addresses.count == 1,"CLI family selection reaches bind")
  let port = listener.addresses[0].port
  let first = try Peer(port:port,authentication:true)
  defer { withExtendedLifetime(first) {} }
  try await until("CLI first peer") { listener.incoming.count == 1 }
  let peer = listener.incoming[0]; listener.accept(peer)
  try check(models.isEmpty && listener.canAccept(peer),"failed window opening releases reservation and keeps credential ownership")
  gate.enabled = true; listener.accept(peer)
  try await until("CLI launch authentication") { models.first?.session?.snapshot.state == .connected && models.first?.busy == false }
  try check(native_test_peer_verified(first.raw) != 0 && native_test_peer_shared(first.raw) == 0 &&
    models[0].session?.clipboardSendEnabled == true,"environment credential and CLI policies reach first reverse handshake")
  try check(!models[0].credentials.supportsRemembering && models[0].history == nil && !models[0].canExportDocument,
    "explicit launch inputs never enable reverse persistence")
  let second = try Peer(port:port,authentication:true)
  defer { withExtendedLifetime(second) {} }
  try await until("CLI second peer") { listener.incoming.count == 1 }
  listener.accept(listener.incoming[0])
  try await until("CLI second interactive prompt") { models.count == 2 && models[1].session?.prompt != nil && !models[1].credentials.isWorking }
  try await Task.sleep(for:.milliseconds(40))
  let fileReads = await reader.calls
  try check(models[1].session?.snapshot.state != .connected && captured.claim() == nil,
    "second incoming window cannot reuse captured credentials or recreate PasswordFile policy")
  try check(fileReads == 0,"environment wins over file, and later peers do not reopen the launch password file")
  listener.stop(); listener.startLaunchIfNeeded()
  try await until("CLI stopped") { listener.phase == .stopped }
  try check(models[0].session?.snapshot.state == .connected,"CLI listener stop preserves accepted session")
  var user: [UInt8] = [], secret = Array("password".utf8)
  try models[1].credentials.submit(models[1].session!.prompt!,username:&user,password:&secret)
  try await until("second manual authentication") { models[1].session?.snapshot.state == .connected && !models[1].busy }
  for model in models { await model.close() }; await listener.close()

  password = Array("password".utf8)
  let unclaimed = try NativeLaunchCredentialInputs(username:&username,password:&password)
  launch.credentials = unclaimed
  let cancelled = ListenerModel(runtime:runtime,launch:launch) { _ in false }
  cancelled.stop(); cancelled.startLaunchIfNeeded()
  try check(cancelled.phase == .idle && unclaimed.claim() == nil,"stop before scene appearance revokes bind and credentials")
  await cancelled.close()
  password = Array("password".utf8)
  let closeInput = try NativeLaunchCredentialInputs(username:&username,password:&password)
  launch.credentials = closeInput
  let closed = ListenerModel(runtime:runtime,launch:launch) { _ in false }
  await closed.close(); closed.startLaunchIfNeeded()
  try check(closed.addresses.isEmpty && closeInput.claim() == nil,"window close revokes pending launch")
  try await runtime.shutdown(); await store.close()
}
actor ListenerDocumentReader: NativeDocumentReading {
  var body: String
  private(set) var calls = 0
  private(set) var pending = false
  var blocked: Bool
  private var continuation: CheckedContinuation<Void,Never>?
  init(_ body: String, blocked: Bool = false) { self.body = body; self.blocked = blocked }
  func replace(_ body: String) { self.body = body }
  func resume() { blocked = false; continuation?.resume(); continuation = nil }
  func read(_ url: URL) async throws -> Data {
    calls += 1
    if blocked { pending = true; await withCheckedContinuation { continuation = $0 }; pending = false }
    return Data(("TidyVNC Configuration file Version 1.0\n"+body).utf8)
  }
}
@MainActor final class ListenerScreens: NativeDisplaySource {
  var connected = true
  func read() -> [NativeDisplay] {
    guard connected else { return [] }
    let bounds = NativeDisplayRectangle(x:0,y:0,width:1000,height:800)
    return [.init(id:.init("listener-screen"),name:"Listener Screen",bounds:bounds,workArea:bounds,backingScale:1,isPrimary:true)]
  }
}
@MainActor func verifyFileLaunch() async throws {
  let runtime = try NativeRuntime(sessionCapacity:2), store = NativePreferencesStore(backing:try Preferences())
  let screens = ListenerScreens()
  let displays = NativeDisplayService(source:screens,notifications:NotificationCenter(),workspaceNotifications:NotificationCenter())
  let launch = try NativeInvocationBootstrap.launch(.init(arguments:["-listen","-UseIPv6=off","-Shared",
    "-SecurityTypes=VncAuth","-SendClipboard=off","./file.tidyvnc"]),workingDirectory:"/launch")
  let reader = ListenerDocumentReader("ServerName=0\nSecurityTypes=None\nShared=off\nSendClipboard=on\nFullScreenMode=Selected\nFullScreenSelectedMonitors=99\nAlwaysCursor=off\nCursorType=System\nFuture=private-value\n")
  var models: [ConnectionModel] = []
  let listener = ListenerModel(runtime:runtime,launch:launch,preferences:store,displays:displays,documentReader:reader) { request in
    models.append(ConnectionModel(runtime:runtime,preferences:store,displays:displays,reverse:request) { _,_ in }); return true
  }
  let controller = ListenerWindowController(model:listener) { _ in }; controller.showWindow(nil)
  listener.startLaunchIfNeeded(); listener.start()
  let preparation = listener.preparation!
  try await until("file mapping") { !preparation.isLoading }
  try check(preparation.session == nil && preparation.prepared == nil && listener.addresses.isEmpty && !listener.canStart,
    "file startup cannot bind or allocate a session before review")
  let mapping = preparation.documentMapping!
  preparation.resolveDocumentMapping(mapping.id,assignments:[99:.init("listener-screen")])
  let firstReview = preparation.documentReview!.id
  preparation.editDocumentMapping(firstReview)
  preparation.resolveDocumentMapping(preparation.documentMapping!.id,assignments:[99:.init("listener-screen")])
  let old = preparation.documentReview!.id
  try check(preparation.documentReview?.resolution.listenPort == 0 && preparation.documentReview?.resolution.notices.count == 1,
    "listener port and ignored field shown for review")
  try await render(controller,"file-review")
  screens.connected = false; displays.refresh(); listener.acceptDocument(old)
  try check(!preparation.isReady && listener.addresses.isEmpty,"topology change revokes file approval before bind")
  screens.connected = true; displays.refresh()
  preparation.resolveDocumentMapping(preparation.documentMapping!.id,assignments:[99:.init("listener-screen")])
  listener.acceptDocument(old)
  try check(!preparation.isReady,"stale approval cannot start listener")
  listener.acceptDocument(preparation.documentReview!.id)
  try await until("file listening") { listener.phase == .listening }
  try check(preparation.session == nil && preparation.prepared != nil,"approved listener owns configuration without a hidden session")
  // Make subsequent store/file access observably invalid. Accepted windows must
  // use the exact reviewed value, including metadata and inactive cursor shape.
  await store.close(); await reader.replace("ServerName=bad-private\nShared=broken\n")
  let first = try Peer(port:listener.addresses[0].port), second = try Peer(port:listener.addresses[0].port)
  defer { withExtendedLifetime((first,second)) {} }
  try await until("file incoming") { listener.incoming.count == 2 }
  let peers = listener.incoming
  screens.connected = false; displays.refresh(); listener.accept(peers[0])
  try check(models.isEmpty && listener.issue != nil && listener.canAccept(peers[0]),"missing reviewed display prevents acceptance but permits rejection")
  screens.connected = true; displays.refresh()
  listener.accept(peers[0]); listener.accept(peers[1])
  try await until("file peers connected") { models.count == 2 && models.allSatisfy { $0.session?.snapshot.state == .connected && !$0.busy } }
  let reads = await reader.calls
  try check(reads == 1 && models.allSatisfy { $0.defaults?.documentResolution?.cursorType == .system && $0.session?.clipboardSendEnabled == true },
    "file read once; incoming windows preserve reviewed configuration and metadata without store access")
  try check(native_test_peer_shared(first.raw) == 0 && native_test_peer_shared(second.raw) == 0 &&
    models.allSatisfy { $0.session?.initialSecuritySource == .document && $0.session?.initialFullscreenPolicy.selectedDisplays == [.init("listener-screen")] },
    "file wins over CLI and native defaults for both handshakes")
  listener.stop(); try await until("file stopped") { listener.phase == .stopped }
  try check(models.allSatisfy { $0.session?.snapshot.state == .connected },"stopping file listener preserves admitted sessions")
  for model in models { await model.close() }
  await controller.shutdown()

  let nextStore = NativePreferencesStore(backing:try Preferences())
  let blockedReader = ListenerDocumentReader("ServerName=0\n",blocked:true)
  let cancelled = ListenerModel(runtime:runtime,launch:launch,preferences:nextStore,displays:displays,documentReader:blockedReader) { _ in false }
  cancelled.startLaunchIfNeeded()
  for _ in 0..<1000 { if await blockedReader.pending { break }; try await Task.sleep(for:.milliseconds(2)) }
  let wasPending = await blockedReader.pending
  try check(wasPending,"listener file read suspended")
  cancelled.requestClose(); await blockedReader.resume(); await cancelled.close()
  try check(cancelled.addresses.isEmpty && cancelled.preparation?.prepared == nil && cancelled.preparation?.documentReview == nil,
    "window close drains read and discards late review without binding")
  var user: [UInt8]?, secret: [UInt8]? = Array("password".utf8)
  let inputs = try NativeLaunchCredentialInputs(username:&user,password:&secret)
  var ownedLaunch = launch; ownedLaunch.credentials = inputs
  let reviewed = ListenerModel(runtime:runtime,launch:ownedLaunch,preferences:nextStore,displays:displays,
    documentReader:ListenerDocumentReader("ServerName=0\n")) { _ in false }
  reviewed.startLaunchIfNeeded(); try await until("cancel review") { reviewed.preparation?.documentReview != nil }
  let reviewID = reviewed.preparation!.documentReview!.id
  reviewed.cancelDocument(reviewID); reviewed.acceptDocument(reviewID)
  try check(inputs.claim() == nil && reviewed.addresses.isEmpty && reviewed.preparation?.isReady == false,
    "cancelled review clears launch credentials and stale accept cannot bind")
  await reviewed.close(); await nextStore.close(); displays.stop(); try await runtime.shutdown()
}
func verifyListenDocumentPorts() throws {
  func resolve(_ body: String) throws -> NativeDocumentResolution {
    try NativeDocumentResolution(document:.init(data:Data(("TidyVNC Configuration file Version 1.0\n"+body).utf8)),endpointUse:.listenPort)
  }
  try check(try resolve("").listenPort == 5500 && resolve("ServerName=\n").listenPort == 5500,"absent/empty listener file port defaults")
  try check(try resolve("ServerName=00065535\n").listenPort == 65535 && resolve("ServerName=0\n").listenPort == 0,"checked file port boundaries")
  for value in ["65536","999999999999999999","5500tail","private.invalid","+5500","-1"] {
    do { _ = try resolve("ServerName=\(value)\nServerName=0\n"); throw Failure(message:"invalid duplicate listen port accepted") }
    catch let error as NativeDocumentResolutionFailure {
      try check(error.reason == .invalidListenPort && error.line == 2 && !error.description.contains("private.invalid"),"typed redacted per-occurrence port error")
    }
  }
}
@MainActor final class Harness: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      do { try await Main.run(); NSApp.terminate(nil) }
      catch { fputs("Listener fixture failed: \(error)\n",stderr); exit(1) }
    }
  }
}
@main struct Main {
  @MainActor static func main() {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = Harness(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
  @MainActor static func run() async throws {
    if CommandLine.arguments.contains("--file-preview") {
      let runtime = try NativeRuntime(), store = NativePreferencesStore(backing:try Preferences())
      let launch = try NativeInvocationBootstrap.launch(.init(arguments:["-listen","-UseIPv6=off","./preview.tidyvnc"]),workingDirectory:"/tmp")
      let model = ListenerModel(runtime:runtime,launch:launch,preferences:store,
        documentReader:ListenerDocumentReader("ServerName=0\nShared=on\nSecurityTypes=None\nFutureOption=ignored\n")) { _ in false }
      let controller = ListenerWindowController(model:model) { _ in }
      controller.showWindow(nil); NSApp.activate(ignoringOtherApps:true); model.startLaunchIfNeeded()
      try await until("file preview review") { model.preparation?.documentReview != nil }
      print("File listener review ready")
      var peers: [Peer] = []
      let deadline = Date().addingTimeInterval(120)
      while Date() < deadline && !FileManager.default.fileExists(atPath:"/tmp/tidyvnc-file-listen-preview-stop") {
        if let review = model.preparation?.documentReview,
           FileManager.default.fileExists(atPath:"/tmp/tidyvnc-file-listen-preview-accept") { model.acceptDocument(review.id) }
        if model.phase == .listening, peers.isEmpty {
          peers = [try Peer(port:model.addresses[0].port),try Peer(port:model.addresses[0].port)]
          print("File listener preview listening")
        }
        try await Task.sleep(for:.milliseconds(200))
      }
      await controller.shutdown(); try await runtime.shutdown(); await store.close()
      withExtendedLifetime(peers) {}; return
    }
    if CommandLine.arguments.contains("--preview") {
      let runtime = try NativeRuntime()
      let model = ListenerModel(runtime:runtime) { _ in false }
      let controller = ListenerWindowController(model:model) { _ in }
      controller.showWindow(nil); NSApp.activate(ignoringOtherApps:true)
      model.port = "0"; model.ipv6 = false; model.start()
      try await until("preview listening") { model.phase == .listening }
      let first = try Peer(port:model.addresses[0].port), second = try Peer(port:model.addresses[0].port)
      defer { withExtendedLifetime((first,second)) {} }
      print("Listener preview ready")
      let deadline = Date().addingTimeInterval(120)
      while Date() < deadline && !FileManager.default.fileExists(atPath:"/tmp/tidyvnc-listen-ui-preview-stop") {
        try await Task.sleep(for:.milliseconds(200))
      }
      await controller.shutdown(); try await runtime.shutdown(); return
    }
    try verifyListenDocumentPorts(); try await verify(); try await verifyLaunch(); try await verifyFileLaunch()
    print("PASS listener UI/model, reverse defaults, scoped windows and shutdown")
  }
}
