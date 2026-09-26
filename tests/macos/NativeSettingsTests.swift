// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
final class SettingsBacking: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  func read() throws -> Data? { lock.withLock { data } }
  func write(_ value: Data) throws { lock.withLock { data = value } }
}
@MainActor func waitForDraft(_ draft: NativePreferencesDraft) async throws {
  for _ in 0..<1000 { if !draft.isBusy { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Settings draft timed out")
}
@MainActor func capture<Content: View>(_ content: Content, name: String, directory: URL, dark: Bool,
                                     size: NSSize = NSSize(width: 620, height: 680),
                                     ready: @MainActor () async throws -> Void) async throws {
  let view = NSHostingView(rootView: content
    .environment(\.layoutDirection, CommandLine.arguments.contains("--rtl") ? .rightToLeft : .leftToRight)
    .environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
  let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
  window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  window.isReleasedWhenClosed = false; window.contentView = view
  defer { window.contentView = nil; window.close() }
  view.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(50)); try await ready()
  view.layoutSubtreeIfNeeded()
  let fitting = view.fittingSize
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "No settings bitmap") }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "No settings PNG") }
  try data.write(to: directory.appendingPathComponent(name + ".png"))
  guard fitting.width <= size.width, fitting.height <= size.height else { throw Failure(message: "Settings \(name) exceeds test window: \(fitting)") }
  print("PASS rendered \(name): fitting \(fitting), bitmap \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
}
@MainActor func render(_ model: NativePreferencesDraft, name: String, directory: URL, dark: Bool,
                       section: PreferencesSettingsView.Section) async throws {
  try await capture(PreferencesSettingsView(model: model, section: section), name: name, directory: directory, dark: dark) {
    try await waitForDraft(model)
  }
}
@MainActor func waitForEncoding(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Encoding rendering fixture timed out")
}
@MainActor final class ResizeDisplaySource: NativeDisplaySource {
  var values: [NativeDisplay] = []
  func read() throws -> [NativeDisplay] { values }
}
@MainActor func renderDisplayResize(session: NativeSession, directory: URL) async throws {
  let source = ResizeDisplaySource()
  let a = NativeDisplayRectangle(x:-1000,y:0,width:1000,height:800)
  let b = NativeDisplayRectangle(x:0,y:-200,width:1200,height:1000)
  let original: [NativeDisplay] = [
    .init(id:.init("a"),name:"Retina display",bounds:a,workArea:a,backingScale:2,isPrimary:false),
    .init(id:.init("b"),name:"External display",bounds:b,workArea:b,backingScale:1,isPrimary:true)]
  source.values = original
  let service = NativeDisplayService(source:source,notifications:NotificationCenter(),workspaceNotifications:NotificationCenter())
  defer { service.stop() }
  for dark in [false,true] {
    for fixture in ["all","selected","empty","changed","missing","overlap"] {
      source.values = original; service.refresh()
      let draft = NativeRemoteResizeDraft(session:session,displays:service); draft.reload()
      draft.source = .selectedDisplays; draft.devicePixels = true
      if fixture == "all" { draft.source = .allDisplays }
      if fixture == "selected" { draft.selectedDisplays = [.init("a")] }
      if fixture == "empty" { draft.selectedDisplays = [] }
      if fixture == "changed" || fixture == "missing" { source.values = [original[1]]; service.refresh() }
      if fixture == "missing" { draft.reload() }
      if fixture == "overlap" {
        source.values = [original[0],.init(id:.init("b"),name:"Mirrored display",bounds:a,workArea:a,backingScale:1,isPrimary:true)]
        service.refresh(); draft.reload()
      }
      if ["empty","changed","missing","overlap"].contains(fixture), draft.canApply { throw Failure(message:"Invalid display fixture enabled Resize") }
      try await capture(RemoteResizeSheet(model:draft,dismiss:{}),name:"display-resize-"+fixture+(dark ? "-dark" : ""),directory:directory,dark:dark) {}
      await draft.close()
    }
  }
}
@MainActor func renderRemoteResize(directory: URL) async throws {
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  let peer = native_resize_peer_create()!; defer { native_resize_peer_destroy(peer) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  try await waitForEncoding { session.snapshot.supportsResize }
  for dark in [false,true] {
    for fixture in ["draft","rejected","pending","applied","multiple"] {
      if fixture == "multiple" {
        let multi = try NativeRemoteLayout(width:6,height:2,screens:[.init(id:7,x:0,y:0,width:2,height:2),.init(id:8,x:4,y:0,width:2,height:2)])
        _ = try await session.requestDesktopLayout(multi,expectedGeneration:session.generation)
      }
      let draft = NativeRemoteResizeDraft(session:session); draft.reload(); draft.width = String(session.snapshot.width + 1)
      if fixture == "rejected" { native_resize_peer_reply(peer,1); draft.apply(); try await waitForEncoding { !draft.isBusy } }
      if fixture == "applied" { native_resize_peer_reply(peer,0); draft.apply(); try await waitForEncoding { !draft.isBusy } }
      if fixture == "pending" { native_resize_peer_reply(peer,UInt32.max); draft.apply(); try await waitForEncoding { session.snapshot.resizePending } }
      try await capture(RemoteResizeSheet(model:draft,dismiss:{}),name:"remote-resize-" + fixture + (dark ? "-dark" : ""),directory:directory,dark:dark) {}
      native_resize_peer_reply(peer,0); await draft.close()
      try await waitForEncoding { !session.snapshot.resizePending }
    }
  }
  try await renderDisplayResize(session:session,directory:directory)
  try await session.close(); try await runtime.shutdown()
}
@MainActor func renderLiveEncoding(directory: URL) async throws {
  for dark in [false, true] {
    for fixture in ["draft", "applied", "conflict", "pending", "cancelled"] {
      let target = try EncodingTarget(), model = NativeSessionEncodingDraft(target: target)
      model.reload(); model.setEncoding(.quality, value: "5")
      if fixture == "applied" { model.apply(); try await waitForEncoding { !model.isBusy } }
      if fixture == "conflict" {
        target.options = try target.options.applying([.init("QualityLevel", "7")], source: .session); model.apply()
      }
      if fixture == "pending" || fixture == "cancelled" {
        target.behavior = .suspendAfter; model.apply(); try await waitForEncoding { target.isSuspended }
        if fixture == "cancelled" { model.cancelApply(); target.release(); try await waitForEncoding { !model.isBusy } }
      }
      try await capture(SessionEncodingSheet(model: model, dismiss: {}), name: "live-" + fixture + (dark ? "-dark" : ""),
                        directory: directory, dark: dark) {}
      if fixture == "applied" && !model.didApply { throw Failure(message: "Applied fixture lost") }
      if fixture == "conflict" && model.error != .changed { throw Failure(message: "Conflict fixture lost") }
      if fixture == "cancelled" && model.error != .cancelled { throw Failure(message: "Cancellation fixture lost") }
      model.stop(); target.release(); await model.close()
    }
  }
}
@MainActor func renderScaling(directory: URL) async throws {
  for dark in [false, true] {
    for fixture in ["fit", "exact", "percent", "independent", "invalid", "conflict", "nearest", "area"] {
      let state = NativeScalingState(), model = NativeScalingDraft(state: state)
      switch fixture {
      case "exact": model.mode = .exact; model.text = "1920x1080"; model.devicePixels = true
      case "percent": model.mode = .percent; model.text = "137.5"
      case "independent": model.mode = .independent; model.text = "125%x80%"
      case "invalid": model.mode = .percent; model.text = "10000.01"
      case "nearest": model.filter = .nearest
      case "area": model.mode = .exact; model.text = "640x480"; model.filter = .area
      case "conflict":
        let other = NativeScalingDraft(state: state); other.mode = .automatic; _ = other.apply()
        model.mode = .fitWidth; _ = model.apply()
      default: break
      }
      try await capture(ScalingSettingsSheet(model: model, dismiss: {}), name: "scaling-" + fixture + (dark ? "-dark" : ""),
                        directory: directory, dark: dark, size: NSSize(width: 580, height: 510)) {
        if fixture == "invalid" && model.canApply { throw Failure(message: "Invalid scale enabled Apply") }
        if fixture == "conflict" && model.issue != .changed { throw Failure(message: "Missing scaling conflict") }
      }
    }
  }
}
@MainActor func renderRecentHistory(directory: URL) async throws {
  for dark in [false, true] {
    for fixture in ["empty", "recent", "connected", "error", "pending"] {
      let backing = HistoryBacking(), store = NativeProfileHistoryStore(backing: backing), model = NativeRecentHistory(store: store)
      var snapshot = try await store.read()
      if fixture != "empty" {
        for endpoint in ["localhost:1", "[fe80::1%en0]::5901", "/tmp/remote desktop.sock", "a-long-hostname.for-the-development-lab.example.internal::5902"] {
          snapshot = try await store.recordRecent(endpoint, expected: snapshot.revision)
        }
      }
      model.reload(); try await waitForEncoding { !model.isBusy }
      let gate = HistoryGate()
      if fixture == "error" { backing.fail(read: .denied); model.reload(); try await waitForEncoding { !model.isBusy } }
      if fixture == "pending" { backing.gate(write: gate); model.recordSuccessful("new-host"); try await waitForEncoding { gate.isEntered } }
      try await capture(RecentConnectionsPanel(model: model, canSelect: fixture != "connected", select: { _ in }),
                        name: "history-" + fixture + (dark ? "-dark" : ""), directory: directory, dark: dark) {
        if fixture != "pending" { try await waitForEncoding { !model.isBusy } }
      }
      if fixture == "error" && model.error != .denied { throw Failure(message: "History error fixture lost") }
      model.stop(); gate.release(); await model.close(); await store.close()
    }
  }
}
@MainActor func renderProfiles(directory: URL) async throws {
  for dark in [false, true] {
    for fixture in ["empty", "saved", "minimum", "editing", "scaling", "resize", "resize-invalid", "invalid-address", "conflict", "error", "pending"] {
      let backing = HistoryBacking(), store = NativeProfileHistoryStore(backing: backing)
      let preferences = NativePreferencesStore(backing: SettingsBacking())
      let model = NativeProfileLibrary(store: store, preferences: preferences)
      let profile = NativeConnectionProfile(name: "Design lab — long profile name", endpoint: "a-long-hostname.for-the-development-lab.example.internal::5902", credentialReference: UUID())
      if fixture != "empty" { _ = try await store.upsert(profile, expected: nil) }
      model.reload(); try await waitForEncoding { !model.isBusy }
      if fixture != "empty" { model.select(profile.id) }
      if ["editing", "conflict", "pending"].contains(fixture) {
        model.setEncoding(.autoSelect, value: "off"); model.setEncoding(.quality, value: "5")
        model.draft?.settings.clipboardReceive = false
      }
      if fixture == "resize" { model.draft?.settings.remoteResize = .init(enabled:false,initialSize:"1920x1080") }
      if fixture == "resize-invalid" {
        model.draft?.settings.remoteResize = .init(initialSize:"1x65536")
        if model.canSave { throw Failure(message:"invalid resize profile enabled Save") }
      }
      if fixture == "scaling" {
        var patch = NativeScalingPreferences(); patch.scaling = "1920x1080"; patch.filter = "area"
        model.draft?.settings.scaling = patch
      }
      if fixture == "invalid-address" { model.draft?.endpoint = "host::70000" }
      let gate = HistoryGate()
      if fixture == "conflict" {
        _ = try await store.recordRecent("changed", expected: (try await store.read()).revision)
        model.save(); try await waitForEncoding { !model.isBusy }
      }
      if fixture == "error" { backing.fail(read: .denied); model.reload(); try await waitForEncoding { !model.isBusy } }
      if fixture == "pending" { backing.gate(write: gate); model.save(); try await waitForEncoding { gate.isEntered } }
      try await capture(ProfileLibraryView(model: model, open: { _ in }), name: "profiles-" + fixture + (dark ? "-dark" : ""),
                        directory: directory, dark: dark, size: fixture == "minimum" ? NSSize(width: 900, height: 640) : NSSize(width: 940, height: 680)) {
        if fixture != "pending" { try await waitForEncoding { !model.isBusy } }
        if fixture == "invalid-address" && (model.endpointIssue != .invalidPort || model.canSave) {
          throw Failure(message: "Invalid address fixture lost")
        }
      }
      if fixture == "conflict" && model.error != .conflict { throw Failure(message: "Profile conflict lost") }
      if fixture == "error" && model.error != .denied { throw Failure(message: "Profile error lost") }
      model.stop(); gate.release(); await model.close(); await preferences.close(); await store.close()
    }
  }
}
@MainActor func renderInput(directory: URL) async throws {
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  for dark in [false, true] {
    for fixture in ["defaults", "view-only", "middle", "shortcuts-off", "shortcuts-all", "dot", "system", "conflict", "closed"] {
      let state = NativeInputState(); state.bind(session)
      let draft = NativeInputDraft(state: state)
      if fixture == "view-only" { draft.viewOnly = true }
      if fixture == "shortcuts-off" { draft.shortcutModifiers = []; draft.fullscreenSystemKeys = false }
      if fixture == "shortcuts-all" { draft.shortcutModifiers = [.control,.shift,.option,.command] }
      if fixture == "middle" { draft.emulateMiddle = true }
      if fixture == "dot" { draft.cursorFallback = .dot }
      if fixture == "system" { draft.cursorFallback = .system }
      if fixture == "conflict" {
        let newer = NativeInputDraft(state: state); newer.cursorFallback = .dot
        guard newer.apply() else { throw Failure(message: "Input fixture apply failed") }
        draft.viewOnly = true
        guard !draft.apply(), draft.issue == .changed else { throw Failure(message: "Input conflict lost") }
      }
      if fixture == "closed" { state.stop(); _ = draft.apply() }
      try await capture(InputSettingsSheet(model: draft, dismiss: {}), name: "input-" + fixture + (dark ? "-dark" : ""),
        directory: directory, dark: dark, size: NSSize(width: 580, height: 740)) {}
      state.stop()
    }
  }
  for dark in [false, true] {
    try await capture(ConnectionInformationSheet(endpoint: "a-long-hostname.for-the-development-lab.example.internal::5902", session: session, copy: { _ in }, dismiss: {}),
      name: "connection-information" + (dark ? "-dark" : ""), directory: directory, dark: dark, size: NSSize(width: 620,height: 710)) {}
  }
  guard let information = session.information else { throw Failure(message: "Missing overlay fixture information") }
  for dark in [false, true] {
    for width in [320, 640] {
      try await capture(ConnectionStatisticsOverlay(information: information).padding(12),
        name: "connection-statistics-\(width)" + (dark ? "-dark" : ""), directory: directory,
        dark: dark, size: NSSize(width: width, height: 220)) {}
    }
  }
  let authPreferences = NativePreferencesStore(backing: SettingsBacking())
  let authStore = NativeCredentialStore() // Render only; no backend operation is invoked.
  let authModel = ConnectionModel(runtime: runtime, preferences: authPreferences, credentialStore: authStore) { _,_ in }
  for dark in [false, true] {
    for secure in [false, true] {
      let request = NativePrompt(id: 1, generation: session.generation, kind: .credentials, secure: secure, securityType: secure ? 262 : 2,
        usernameRequired: secure, certificateStatus: 0,
        serverName: "a-long-hostname.for-the-development-lab.example.internal::5902",
        fingerprint: "", identity: Data())
      try await capture(AuthenticationSheet(model: authModel, session: session, request: request),
        name: "authentication-credentials-\(secure ? "protected" : "unassured")" + (dark ? "-dark" : ""), directory: directory,
        dark: dark, size: NSSize(width: 520, height: 580)) {}
      try await capture(AuthenticationSheet(model: authModel, session: session, request: request, retention: .remember),
        name: "authentication-remember-\(secure ? "protected" : "unassured")" + (dark ? "-dark" : ""), directory: directory,
        dark: dark, size: NSSize(width: 520, height: 640)) {}
    }
  }
  // The unassured warning wraps to two lines at the sheet width; none may be cut.
  var warning = NSColor.black
  NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { warning = NSColor.nativeWarningText.usingColorSpace(.sRGB)! }
  let unassured = NativePrompt(id: 1, generation: session.generation, kind: .credentials, secure: false, securityType: 2,
    usernameRequired: false, certificateStatus: 0, serverName: "127.0.0.1", fingerprint: "", identity: Data())
  let warningLines = try await presentedSheetLines(AuthenticationSheet(model: authModel, session: session, request: unassured),
    name: "authentication-unassured", directory: directory) { color in
      abs(color.redComponent - warning.redComponent) < 0.12 && abs(color.greenComponent - warning.greenComponent) < 0.12
        && abs(color.blueComponent - warning.blueComponent) < 0.12
    }
  guard warningLines == 2 else { throw Failure(message: "presented authentication sheet shows \(warningLines) of 2 credential-warning lines") }
  for dark in [false, true] {
    for (name, kind, status, identity, compatibility) in [
      ("unknown-issuer", NativePrompt.Kind.certificate, UInt32(66), trustFixtureCertificate, ""),
      ("expired-name", .certificate, UInt32(2 | 1024 | 16384), trustFixtureCertificate, ""),
      ("revoked", .certificate, UInt32(34), trustFixtureCertificate, ""),
      ("unknown-status", .certificate, UInt32(1 << 31), trustFixtureCertificate, ""),
      ("overflow", .certificate, UInt32.max, trustFixtureCertificate, ""),
      ("malformed", .certificate, UInt32(66), Data([1,2,3]), ""),
      ("host-key", .hostKey, UInt32(0), hostKeyFixture, hostKeyFixtureCompatibility)
    ] {
      let prompt = NativePrompt(id: 2, generation: session.generation, kind: kind, secure: false,
        usernameRequired: false, certificateStatus: status,
        serverName: "a-long-hostname.for-the-development-lab.example.internal::5902",
        fingerprint: compatibility, identity: identity)
      try await capture(AuthenticationSheet(model: authModel, session: session, request: prompt),
        name: "trust-" + name + (dark ? "-dark" : ""), directory: directory,
        dark: dark, size: NSSize(width: 520, height: 680)) {}
    }
  }
  let changedPrompt = NativePrompt(id: 3, generation: session.generation, kind: .certificate, secure: false,
    usernameRequired: false, certificateStatus: 66, serverName: "fixture.invalid", fingerprint: "", identity: trustFixtureCertificate)
  struct RenderKey: NativeCertificateKeyMaterial {
    let spki = Data([1,2,3])
    func digest(_ algorithm: UInt32) throws -> Data {
      guard algorithm == 6 else { throw NativeTrustStoreIssue.unsupportedDigest }
      return Data([1])
    }
  }
  let changed = try NativeLegacyTrustCodec.lookup(data: Data("|g0|fixture.invalid|*|0|BAUG\n|c0|fixture.invalid|*|0|6|00\n".utf8),
    host: "fixture.invalid", key: RenderKey(), now: 100)
  for dark in [false, true] {
    for (name, issue) in [("changed-key", Optional<String>.none), ("store-error", "Saved certificate exceptions could not be read because access was denied.")] {
      try await capture(ScrollView {
        TrustDetailsView(request: changedPrompt, destination: "fixture.invalid::5902", inspection: issue == nil ? changed : nil, issue: issue)
          .padding(24)
      }.frame(width: 488, height: 620), name: "trust-" + name + (dark ? "-dark" : ""), directory: directory,
        dark: dark, size: NSSize(width: 520, height: 680)) {}
    }
  }
  await authModel.close(); await authStore.close(); await authPreferences.close()
  try await session.close(); try await runtime.shutdown()
}
@MainActor final class TrustRenderTarget: NativeTrustTarget {
  var prompt: NativePrompt?, generation: UInt64 = 7, isClosing = false
  func replyTrust(to request: NativePrompt,allowed: Bool) throws { prompt = nil }
}
struct TrustRenderLegacy: NativeLegacyTrustBacking { func read() throws -> Data? { nil } }
struct TrustRenderKey: NativeCertificateKeyMaterial {
  let spki: Data
  func digest(_ algorithm: UInt32) throws -> Data { throw NativeTrustStoreIssue.unsupportedDigest }
}
// A presented sheet takes its height from SwiftUI's sheet sizing, not from the
// larger fixed windows used by capture(). Renders the presented sheet and returns
// the number of separate text-line bands containing the given colour.
@MainActor func presentedSheetLines<Content: View>(_ content: Content, name: String, directory: URL,
                                                   matching: (NSColor) -> Bool) async throws -> Int {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
  window.contentView = NSHostingView(rootView: Color.clear.sheet(isPresented: .constant(true)) { content })
  window.orderFront(nil)
  defer { window.contentView = nil; window.orderOut(nil); window.close() }
  for _ in 0..<200 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
  guard let sheet = window.attachedSheet, let presented = sheet.contentView else { throw Failure(message: "\(name) sheet was not presented") }
  try await Task.sleep(for: .milliseconds(100)); presented.layoutSubtreeIfNeeded()
  guard let bitmap = presented.bitmapImageRepForCachingDisplay(in: presented.bounds)?.converting(to: .sRGB, renderingIntent: .default) else {
    throw Failure(message: "No \(name) sheet bitmap")
  }
  presented.cacheDisplay(in: presented.bounds, to: bitmap)
  try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("presented-" + name + ".png"))
  var bands = 0, inside = false
  for y in 0..<bitmap.pixelsHigh {
    let hit = (0..<bitmap.pixelsWide).contains { x in bitmap.colorAt(x: x, y: y).map(matching) ?? false }
    if hit && !inside { bands += 1 }
    inside = hit
  }
  print("PASS presented \(name) sheet \(sheet.frame.size): \(bands) matching line(s)")
  return bands
}
// Keyboard default/cancel actions of presented sheets (N4.17). Key events go to
// the presented sheet window, as AppKit delivers them to the key sheet.
@MainActor final class Counter { var value = 0 }
@MainActor func presentForKeys<Content: View>(_ content: Content) async throws -> (NSWindow, NSWindow) {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = NSHostingView(rootView: Color.clear.sheet(isPresented: .constant(true)) { content })
  window.orderFront(nil)
  for _ in 0..<200 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
  guard let sheet = window.attachedSheet else { throw Failure(message: "keyboard sheet was not presented") }
  sheet.makeKey(); try await Task.sleep(for: .milliseconds(200))
  return (window, sheet)
}
@MainActor func press(_ sheet: NSWindow, keyCode: UInt16, characters: String) async throws {
  for type in [NSEvent.EventType.keyDown, .keyUp] {
    guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: sheet.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: keyCode) else { throw Failure(message: "no key event") }
    let handled = type == .keyDown && sheet.performKeyEquivalent(with: event)
    // Escape must not depend on keyboard focus: with keyboard navigation off (the
    // default) a sheet without text fields has no focused control to receive it.
    if type == .keyDown && keyCode == 53 && !handled { throw Failure(message: "Escape is not a key equivalent in this sheet") }
    if !handled { sheet.sendEvent(event) }
  }
  try await Task.sleep(for: .milliseconds(200))
}
@MainActor func dismissKeyboard(_ window: NSWindow) { window.contentView = nil; window.orderOut(nil); window.close() }
// Walks a window's key-view loop from its current first responder until it
// returns there, recording each stop's name and window frame.
@MainActor func keyLoop(_ window: NSWindow) async throws -> [(name: String, frame: CGRect)] {
  func current() -> NSView? {
    if let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField { return field }
    return window.firstResponder as? NSView
  }
  func name(_ view: NSView) -> String {
    if let field = view as? NSTextField { return field.placeholderString ?? field.accessibilityLabel() ?? "field" }
    if let label = view.accessibilityLabel(), !label.isEmpty { return label }
    if let button = view as? NSButton, !button.title.isEmpty { return button.title }
    return String(describing: type(of: view))
  }
  if current() == nil { window.selectNextKeyView(nil); try await Task.sleep(for: .milliseconds(60)) }
  guard let start = current() else { throw Failure(message: "no initial key view") }
  func stop(_ view: NSView) -> (name: String, frame: CGRect) { (name(view), view.convert(view.bounds, to: nil)) }
  var stops = [stop(start)]
  for _ in 0..<40 {
    guard let view = current() else { break }
    window.selectKeyView(following: view); try await Task.sleep(for: .milliseconds(60))
    guard let next = current() else { break }
    if next === start { return stops }
    stops.append(stop(next))
  }
  throw Failure(message: "key-view loop did not close: \(stops.map(\.name))")
}
@MainActor func keyboardActions() async throws {
  let escape = (UInt16(53), "\u{1b}"), enter = (UInt16(36), "\r")
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  // Input: Escape cancels; Return with no change does nothing; Return applies a change.
  let input = NativeInputState(); input.bind(session)
  for (name, change, key, expectDismiss, expectViewOnly) in [
    ("input escape", true, escape, true, false), ("input return unchanged", false, enter, false, false),
    ("input return applies", true, enter, true, true)] {
    let dismissed = Counter(), draft = NativeInputDraft(state: input)
    if change { draft.viewOnly = !input.value.viewOnly }
    let before = input.value.viewOnly
    let (window, sheet) = try await presentForKeys(InputSettingsSheet(model: draft, dismiss: { dismissed.value += 1 }))
    try await press(sheet, keyCode: key.0, characters: key.1)
    dismissKeyboard(window)
    guard (dismissed.value == 1) == expectDismiss, (input.value.viewOnly != before) == expectViewOnly else {
      throw Failure(message: "\(name): dismissed \(dismissed.value), view-only \(before) -> \(input.value.viewOnly)")
    }
    if expectViewOnly { let undo = NativeInputDraft(state: input); undo.viewOnly = before; _ = undo.apply() }
    print("PASS keyboard \(name)")
  }
  input.stop()
  // Scaling: Escape cancels without applying.
  let scalingState = NativeScalingState(), scaling = NativeScalingDraft(state: scalingState), scalingDismissed = Counter()
  scaling.filter = .nearest
  let (scalingWindow, scalingSheet) = try await presentForKeys(ScalingSettingsSheet(model: scaling, dismiss: { scalingDismissed.value += 1 }))
  try await press(scalingSheet, keyCode: escape.0, characters: escape.1)
  dismissKeyboard(scalingWindow)
  guard scalingDismissed.value == 1, scalingState.value.filter != .nearest else {
    throw Failure(message: "scaling escape: dismissed \(scalingDismissed.value), filter \(scalingState.value.filter)")
  }
  print("PASS keyboard scaling escape")
  // Live encoding: Escape is Done/Cancel.
  let target = try EncodingTarget(), encoding = NativeSessionEncodingDraft(target: target), encodingDismissed = Counter()
  encoding.reload()
  let (encodingWindow, encodingSheet) = try await presentForKeys(SessionEncodingSheet(model: encoding, dismiss: { encodingDismissed.value += 1 }))
  try await press(encodingSheet, keyCode: escape.0, characters: escape.1)
  dismissKeyboard(encodingWindow)
  guard encodingDismissed.value == 1 else { throw Failure(message: "encoding escape did not dismiss") }
  print("PASS keyboard encoding escape")
  // Information: Return is Done.
  let infoDismissed = Counter()
  let (infoWindow, infoSheet) = try await presentForKeys(ConnectionInformationSheet(endpoint: "fixture.invalid::5901", session: session,
    copy: { _ in }, dismiss: { infoDismissed.value += 1 }))
  try await press(infoSheet, keyCode: enter.0, characters: enter.1)
  dismissKeyboard(infoWindow)
  guard infoDismissed.value == 1 else { throw Failure(message: "information return did not dismiss") }
  print("PASS keyboard information return")
  // Authentication and trust prompts. ConnectionModel.cancel() also cancels the
  // model's trust request (canConnectOnce turns false), which makes Cancel
  // observable; a recording target shows whether any key trusted the certificate.
  final class RecordingTrustTarget: NativeTrustTarget {
    var prompt: NativePrompt?, generation: UInt64 = 7, isClosing = false, replies: [Bool] = []
    func replyTrust(to request: NativePrompt, allowed: Bool) throws { replies.append(allowed) }
  }
  let model = ConnectionModel(runtime: runtime, preferences: NativePreferencesStore(backing: SettingsBacking()),
                              credentialStore: NativeCredentialStore()) { _, _ in }
  // The model binds its trust to its own session once that exists; set up after.
  try await waitForEncoding { model.session != nil }
  try await Task.sleep(for: .milliseconds(200))
  let certificate = NativePrompt(id: 9, generation: 7, kind: .certificate, secure: false, usernameRequired: false,
    certificateStatus: 66, serverName: "fixture.invalid", fingerprint: "", identity: trustFixtureCertificate)
  let credentials = NativePrompt(id: 10, generation: 7, kind: .credentials, secure: false, securityType: 2,
    usernameRequired: false, certificateStatus: 0, serverName: "fixture.invalid", fingerprint: "", identity: Data())
  for (name, request, key, expectCancel) in [("trust without a key stays pending", certificate, nil, false),
                                              ("trust return is cancel", certificate, enter, true),
                                              ("trust escape", certificate, escape, true),
                                              ("authentication escape", credentials, escape, true)] as [(String, NativePrompt, (UInt16, String)?, Bool)] {
    let target = RecordingTrustTarget(); target.prompt = certificate
    model.trust.bind(target); model.trust.beginAttempt(endpoint: "fixture.invalid::5902"); model.trust.inspect(certificate)
    try await waitForTrust { model.trust.canConnectOnce(certificate) }
    let (window, sheet) = try await presentForKeys(AuthenticationSheet(model: model, session: session, request: request,
                                                                       trustModel: model.trust))
    if let key { try await press(sheet, keyCode: key.0, characters: key.1) } else { try await Task.sleep(for: .milliseconds(200)) }
    let active = model.trust.canConnectOnce(certificate), replies = target.replies
    dismissKeyboard(window)
    guard active != expectCancel, !replies.contains(true) else {
      throw Failure(message: "\(name): trust request \(active ? "still active" : "cancelled"), replies \(replies)")
    }
    print("PASS keyboard \(name)")
  }
  // Password sheet key-view loop: every enabled control, in visual order, closing at Password.
  do {
    let (window, sheet) = try await presentForKeys(AuthenticationSheet(model: model, session: session, request: credentials,
                                                                       trustModel: model.trust))
    let stops = try await keyLoop(sheet)
    dismissKeyboard(window)
    // Six stops: Password, lifetime pop-up, Use/Forget Saved Password, Cancel, Authenticate,
    // visited in reading order (AppKit frames: larger maxY is higher on screen).
    let reading = stops.sorted { abs($0.frame.midY - $1.frame.midY) > 4 ? $0.frame.midY > $1.frame.midY : $0.frame.minX < $1.frame.minX }
    guard stops.count == 6, stops.first?.name == "Password", stops.map(\.frame) == reading.map(\.frame) else {
      throw Failure(message: "password sheet key loop \(stops.map { "\($0.name)@\($0.frame.integral)" })")
    }
    print("PASS keyboard password sheet key loop of \(stops.count) stops in reading order, starting at Password")
  }
  // Other sheets: the loop closes and follows reading order.
  func readingOrder(_ stops: [(name: String, frame: CGRect)]) -> Bool {
    stops.map(\.frame) == stops.sorted { abs($0.frame.midY - $1.frame.midY) > 4 ? $0.frame.midY > $1.frame.midY
      : $0.frame.minX < $1.frame.minX }.map(\.frame)
  }
  let loopInput = NativeInputState(); loopInput.bind(session)
  let loopTarget = try EncodingTarget(), encodingDraft = NativeSessionEncodingDraft(target: loopTarget); encodingDraft.reload()
  let sheets: [(String, AnyView)] = [
    ("trust", AnyView(AuthenticationSheet(model: model, session: session, request: certificate, trustModel: model.trust))),
    ("input", AnyView(InputSettingsSheet(model: NativeInputDraft(state: loopInput), dismiss: {}))),
    ("scaling", AnyView(ScalingSettingsSheet(model: NativeScalingDraft(state: NativeScalingState()), dismiss: {}))),
    ("encoding", AnyView(SessionEncodingSheet(model: encodingDraft, dismiss: {}))),
  ]
  for (name, content) in sheets {
    let (window, sheet) = try await presentForKeys(content)
    let stops = try await keyLoop(sheet)
    dismissKeyboard(window)
    guard stops.count >= 2, readingOrder(stops) else {
      throw Failure(message: "\(name) sheet key loop \(stops.map { "\($0.name)@\($0.frame.integral)" })")
    }
    print("PASS keyboard \(name) sheet key loop of \(stops.count) stops in reading order")
  }
  loopInput.stop()
  await model.close()
  try await session.close(); try await runtime.shutdown()
}
@MainActor func waitForTrust(_ ready: () -> Bool) async throws {
  for _ in 0..<1000 { if ready() { return }; try await Task.sleep(for: .milliseconds(3)) }
  throw Failure(message: "Trust render timed out")
}
@MainActor func renderScopedTrust(directory: URL) async throws {
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  let preferences = NativePreferencesStore(backing: SettingsBacking())
  let model = ConnectionModel(runtime: runtime,preferences: preferences) { _,_ in }
  model.endpoint = "fixture.invalid::5901"
  for kind in [NativeTrustKind.certificate,.hostKey] {
  for state in ["add","replace","forgotten"] {
    let backing = HistoryBacking()
    let previous = NativeTrustStore(kind: kind,backing: backing,makeKey: { _ in TrustRenderKey(spki: Data([9])) })
    let destination = try NativeTrustScope(endpoint: model.endpoint,kind: kind), initial = try await previous.read()
    if state == "replace" {
      if kind == .hostKey { var key = hostKeyFixture; key[259] ^= 2; _ = try await previous.saveHostKey(scope: destination,key: key,replacing: false,expected: initial.revision) }
      else { _ = try await previous.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: false,expected: initial.revision) }
    }
    if state == "forgotten" { _ = try await previous.forget(scope: destination,expected: initial.revision) }
    let service = NativeTrustStore(kind: kind,backing: backing,makeKey: { _ in TrustRenderKey(spki: Data([1,2,3])) })
    let legacy = NativeLegacyTrustStore(backing: TrustRenderLegacy(),makeKey: { _ in TrustRenderKey(spki: Data([1,2,3])) })
    let trust = NativeCertificateTrust(store: legacy,savedStore: kind == .certificate ? service : nil,hostKeyStore: kind == .hostKey ? service : nil), target = TrustRenderTarget()
    let request = NativePrompt(id: 1,generation: 7,kind: kind == .certificate ? .certificate : .hostKey,secure: false,usernameRequired: false,
      certificateStatus: kind == .certificate ? 66 : 0,serverName: "fixture.invalid",fingerprint: hostKeyFixtureCompatibility,identity: kind == .certificate ? trustFixtureCertificate : hostKeyFixture)
    target.prompt = request; trust.bind(target); trust.beginAttempt(endpoint: model.endpoint); trust.inspect(request)
    try await waitForTrust { !trust.isWorking }
    for dark in [false,true] {
      try await capture(AuthenticationSheet(model: model,session: session,request: request,trustModel: trust),
        name: (kind == .certificate ? "trust-scoped-" : "trust-host-scoped-") + state + (dark ? "-dark" : ""),directory: directory,dark: dark,size: NSSize(width: 520,height: 800)) {}
    }
    await trust.close(); await legacy.close(); await service.close(); await previous.close()
  }
  }
  let backing = HistoryBacking(), service = NativeTrustStore(backing: backing,makeKey: { _ in TrustRenderKey(spki: Data([1,2,3])) })
  let first = try await service.read()
  let saved = try await service.save(scope: NativeTrustScope(endpoint: "saved.fixture.invalid::5902"),certificate: trustFixtureCertificate,status: 66,replacing: false,expected: first.revision)
  _ = try await service.forget(scope: NativeTrustScope(endpoint: "forgotten.fixture.invalid::5903"),expected: saved.snapshot.revision)
  let library = NativeTrustLibrary(store: service); library.reload(); try await waitForTrust { !library.isWorking }
  for dark in [false,true] {
    try await capture(TrustLibraryView(model: library),name: "trust-library" + (dark ? "-dark" : ""),directory: directory,dark: dark,
      size: NSSize(width: 640,height: 760)) { try await waitForTrust { !library.isWorking } }
  }
  let hostStore = NativeTrustStore(kind: .hostKey,backing: HistoryBacking())
  let emptyHosts = try await hostStore.read()
  let acceptedHost = try await hostStore.saveHostKey(scope: NativeTrustScope(endpoint: "saved.hostkey.invalid:1",kind: .hostKey),key: hostKeyFixture,replacing: false,expected: emptyHosts.revision)
  _ = try await hostStore.forget(scope: NativeTrustScope(endpoint: "forgotten.hostkey.invalid:2",kind: .hostKey),expected: acceptedHost.snapshot.revision)
  let hosts = NativeTrustLibrary(store: hostStore); hosts.reload(); try await waitForTrust { !hosts.isWorking }
  for dark in [false,true] {
    try await capture(TrustLibraryView(model: hosts),name: "trust-host-library" + (dark ? "-dark" : ""),directory: directory,dark: dark,
      size: NSSize(width: 640,height: 760)) { try await waitForTrust { !hosts.isWorking } }
  }
  await hosts.close(); await hostStore.close()
  await library.close(); await service.close(); await model.close(); await preferences.close(); try await session.close(); try await runtime.shutdown()
}
// Flexible connection content must be measured with the proposed viewport, not
// its unconstrained ideal size. The host must not resize this fixture window.
@MainActor func captureViewport<Content: View>(_ content: Content, name: String, directory: URL, dark: Bool,
                                               size: NSSize = NSSize(width:640,height:420)) async throws {
  let host = NSHostingController(rootView:content
    .environment(\.layoutDirection,CommandLine.arguments.contains("--rtl") ? .rightToLeft : .leftToRight)
    .environment(\.colorScheme,dark ? .dark : .light).background(Color(nsColor:.windowBackgroundColor)))
  host.sizingOptions = []
  let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
  window.isReleasedWhenClosed = false; window.contentViewController = host; window.setContentSize(size)
  defer { window.contentViewController = nil; window.close() }
  let view = host.view
  window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua); view.appearance = window.appearance
  view.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(500)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); window.displayIfNeeded()
  let fitting = host.sizeThatFits(in:size)
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"missing connection bitmap") }
  view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
  try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
  let corner = bitmap.colorAt(x:0,y:0)
  let hasContent = stride(from:0,to:bitmap.pixelsHigh,by:max(1,bitmap.pixelsHigh/16)).contains { y in
    stride(from:0,to:bitmap.pixelsWide,by:max(1,bitmap.pixelsWide/16)).contains { x in bitmap.colorAt(x:x,y:y) != corner }
  }
  guard hasContent else { throw Failure(message:"Connection \(name) captured a blank surface") }
  guard view.bounds.size == size, fitting.width <= size.width, fitting.height <= size.height else {
    throw Failure(message:"Connection \(name) fits \(fitting), actual \(view.bounds.size), expected \(size)")
  }
  print("PASS rendered \(name): proposed and actual \(size)")
}

// Tab moves keyboard focus from the server address to the SSH gateway field and
// Shift-Tab back, independent of the system Keyboard Navigation setting (which
// only adds buttons and other controls to the loop).
@MainActor func connectionTabTraversal(model: ConnectionModel, session: NativeSession, displays: NativeDisplayService) async throws {
  model.endpoint = ""; model.sshGatewayText = ""
  let view = NSHostingView(rootView: ConnectionContent(model: model, session: session, displays: displays,
    importAvailability: nil, openImport: {}, openHistoryImport: {}))
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
  defer { window.contentView = nil; window.orderOut(nil); window.close() }
  try await Task.sleep(for: .milliseconds(300)); view.layoutSubtreeIfNeeded()
  // SwiftUI keeps accessibility identifiers off the backing NSTextField; use the placeholders.
  func all(_ root: NSView) -> [NSTextField] { (root as? NSTextField).map { [$0] } ?? [] + root.subviews.flatMap(all) }
  func field(_ placeholder: String) -> NSTextField? { all(view).first { $0.placeholderString == placeholder && $0.isEditable } }
  guard let address = field("Server address"), let gateway = field("SSH gateway (optional)") else {
    throw Failure(message: "connection window text fields not found")
  }
  func focused() -> NSTextField? {
    if let editor = window.firstResponder as? NSTextView { return editor.delegate as? NSTextField }
    return window.firstResponder as? NSTextField
  }
  window.makeKey(); guard window.makeFirstResponder(address) else { throw Failure(message: "address field refused focus") }
  try await Task.sleep(for: .milliseconds(100))
  func press(shift: Bool) async throws {
    // A background test window is never key, so AppKit ignores Tab events sent to
    // a focused button; step the same key-view loop directly there. Text fields
    // receive the real Tab event through their field editor.
    guard focused() != nil else {
      if shift { window.selectPreviousKeyView(nil) } else { window.selectNextKeyView(nil) }
      try await Task.sleep(for: .milliseconds(80)); return
    }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
      window.sendEvent(event)
    }
    try await Task.sleep(for: .milliseconds(120))
  }
  func stop() -> String {
    if let field = focused() { return field === address ? "address" : field === gateway ? "gateway" : "field" }
    return window.firstResponder.map { String(describing: type(of: $0)).contains("Popup") ? "menu button" :
      String(describing: type(of: $0)).contains("Button") ? "button" : "control" } ?? "none"
  }
  // With Keyboard Navigation on, buttons join the loop; either way Tab must reach
  // the gateway field and Shift-Tab must return to the address field.
  var stops: [String] = []
  while stops.last != "gateway" && stops.count < 20 { try await press(shift: false); stops.append(stop()) }
  guard stops.last == "gateway" else { throw Failure(message: "Tab never reached the SSH gateway field: \(stops)") }
  var back: [String] = []
  // Backward: step the key-view loop itself (event delivery was covered forwards).
  while back.last != "address" && back.count < 20 {
    // A focused field's editor has no key-view links; step from the field itself.
    if let field = focused() { window.selectKeyView(preceding: field) } else { window.selectPreviousKeyView(nil) }
    try await Task.sleep(for: .milliseconds(80)); back.append(stop())
  }
  guard back.last == "address" else { throw Failure(message: "Shift-Tab never returned to the address field: \(back)") }
  print("PASS keyboard connection window Tab order address -> \(stops.joined(separator: " -> ")); Shift-Tab back in \(back.count) steps")
}
// Exercise live layout changes in one native window, retaining the desktop view.
@MainActor func compactConnectionWindow(model: ConnectionModel, session: NativeSession,
                                       displays: NativeDisplayService, directory: URL) async throws {
  let host = NSHostingController(rootView: ConnectionContent(model:model,session:session,displays:displays,
    importAvailability:nil,openImport:{},openHistoryImport:{}))
  host.sizingOptions = []
  let window = NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:420),
    styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
  window.isReleasedWhenClosed = false; window.contentViewController = host
  window.toolbarStyle = .unifiedCompact; window.setContentSize(NSSize(width:640,height:420))
  defer { window.contentViewController = nil; window.close() }
  func settle() async throws {
    try await Task.sleep(for:.milliseconds(250)); host.view.layoutSubtreeIfNeeded()
  }
  func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
  func fields() -> [NSTextField] {
    descendants(host.view).compactMap { $0 as? NSTextField }.filter {
      $0.placeholderString == "Server address" || $0.placeholderString == "SSH gateway (optional)"
    }
  }
  func desktop() throws -> NativeDesktopView {
    guard let view = descendants(host.view).compactMap({ $0 as? NativeDesktopView }).first else {
      throw Failure(message:"compact window lost its desktop")
    }
    return view
  }
  try await settle()
  guard fields().isEmpty else { throw Failure(message:"connected window retained destination fields") }
  guard let toolbar = window.toolbar,
        toolbar.items.contains(where:{ $0.itemIdentifier.rawValue.contains("connection.disconnect") }) else {
    throw Failure(message:"connected window has no native Disconnect toolbar item: \(window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? [])")
  }
  guard host.view.bounds.width == 640, host.view.bounds.height == 420 else {
    throw Failure(message:"compact fixture lost its viewport: \(host.view.bounds)")
  }
  let retainedDesktop = try desktop(), withStatus = retainedDesktop.bounds.height
  let connectedGeneration = session.generation
  model.showsStatusBar = false
  try await settle()
  guard try desktop() === retainedDesktop, retainedDesktop.bounds.height > withStatus + 10,
        session.generation == connectedGeneration, session.snapshot.state == .connected else {
    throw Failure(message:"hiding status did not expand the same connected desktop")
  }
  // Include the native toolbar in the compact-window reference image.
  if let frameView = window.contentView?.superview,
     let bitmap = frameView.bitmapImageRepForCachingDisplay(in:frameView.bounds) {
    frameView.cacheDisplay(in:frameView.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("connection-window-compact-toolbar.png"))
  }
  model.showsStatusBar = true
  try await settle()
  guard abs(retainedDesktop.bounds.height - withStatus) < 1 else { throw Failure(message:"status bar did not restore its height") }
  model.showsStatusBar = false
  model.disconnect()
  try await waitForEncoding { !model.busy && session.snapshot.state == .closed }
  try await settle()
  guard fields().count == 2, !model.showsStatusBar, try desktop() === retainedDesktop else {
    throw Failure(message:"disconnect did not restore setup or preserve window presentation state")
  }
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  model.endpoint = "127.0.0.1::\(native_test_peer_port(peer))"
  model.connect()
  try await waitForEncoding { !model.busy && session.snapshot.state == .connected && session.hasFrame }
  try await settle()
  guard fields().isEmpty, !model.showsStatusBar, try desktop() === retainedDesktop else {
    throw Failure(message:"reconnect did not collapse setup or preserve status visibility")
  }
  model.showsStatusBar = true
  print("PASS compact connection window: native Disconnect toolbar, collapsed setup, status height, retained desktop and reconnect")
}

@MainActor func renderConnectionScreen(directory: URL) async throws {
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing:SettingsBacking())
  let historyStore = NativeProfileHistoryStore(backing:HistoryBacking()), history = NativeRecentHistory(store:historyStore)
  history.reload()
  let availability = DefaultsImportAvailability(store:preferences)
  let source = ResizeDisplaySource()
  let bounds = NativeDisplayRectangle(x:0,y:0,width:800,height:600)
  source.values = [.init(id:.init("fixture-screen"),name:"Fixture Display",bounds:bounds,workArea:bounds,backingScale:1,isPrimary:true)]
  let displays = NativeDisplayService(source:source,notifications:NotificationCenter(),workspaceNotifications:NotificationCenter())
  let model = ConnectionModel(runtime:runtime,preferences:preferences,displays:displays,history:history) { _,_ in }
  try await waitForEncoding { model.session != nil && availability.canOffer && history.canImportHistory }
  let session = model.session!
  for dark in [false,true] {
    for fixture in ["first-use","gateway","idle"] {
      model.endpoint = fixture == "first-use" ? "" : "fixture.invalid::5901"
      model.sshGatewayText = fixture == "gateway" ? "ssh://user@gateway.invalid:2222" : ""
      let view = ConnectionContent(model:model,session:session,displays:displays,
        importAvailability:fixture == "first-use" ? availability : nil,openImport:{},openHistoryImport:{})
      try await captureViewport(view,name:"connection-window-"+fixture+(dark ? "-dark" : ""),directory:directory,dark:dark)
    }
  }
  try await connectionTabTraversal(model: model, session: session, displays: displays)
  // A direct fixture handshake avoids credential or tunnel backend operations.
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  model.sshGatewayText = ""; model.endpoint = "127.0.0.1::\(native_test_peer_port(peer))"
  _ = try await session.connect(endpoint:model.endpoint)
  try await waitForEncoding { session.hasFrame && session.information != nil }
  for dark in [false,true] {
    try await captureViewport(ConnectionContent(model:model,session:session,displays:displays,importAvailability:nil,openImport:{},openHistoryImport:{}),
      name:"connection-window-connected"+(dark ? "-dark" : ""),directory:directory,dark:dark)
    try await captureViewport(ConnectionInformationSheet(endpoint:"fixture-%@-开发.invalid::5901",session:session,copy:{ _ in },dismiss:{}),
      name:"connection-details"+(dark ? "-dark" : ""),directory:directory,dark:dark,size:NSSize(width:560,height:650))
    // Statistics have a constrained width and an intrinsic height in fullscreen.
    try await captureViewport(ConnectionStatisticsOverlay(information:session.information!)
      .frame(width:296).fixedSize(horizontal:false,vertical:true).padding(12),
      name:"connection-overlay"+(dark ? "-dark" : ""),directory:directory,dark:dark,size:NSSize(width:320,height:300))
  }
  try await compactConnectionWindow(model:model,session:session,displays:displays,directory:directory)
  await model.close(); await availability.close(); await history.close(); await historyStore.close()
  await preferences.close(); displays.stop(); try await runtime.shutdown()
}

@main struct NativeSettingsTests {
  @MainActor static func main() async {
    _ = NSApplication.shared
    do {
      let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try await keyboardActions()
      try await renderConnectionScreen(directory:directory)
      if CommandLine.arguments.contains("--connection-only") { return }
      try await renderRecentHistory(directory: directory)
      try await renderScaling(directory: directory)
      try await renderInput(directory: directory)
      try await renderProfiles(directory: directory)
      try await renderLiveEncoding(directory: directory)
      try await renderRemoteResize(directory: directory)
      try await renderScopedTrust(directory: directory)
      let optionsRuntime = try NativeRuntime(), optionsSession = try optionsRuntime.makeSession()
      for dark in [false,true] {
        for invalid in [false,true] {
          let policy = NativeRemoteResizePolicyDraft(session:optionsSession)
          policy.enabled = false; policy.initialSize = invalid ? "999999x1080" : "1920x1080"
          try await capture(RemoteResizePolicySheet(model:policy,dismiss:{}),name:"remote-resize-policy" + (invalid ? "-invalid" : "") + (dark ? "-dark" : ""),directory:directory,dark:dark) {}
          policy.cancel()
        }
        let draft = NativeConnectionDraft(session:optionsSession); draft.reload(); draft.shared = true
        try await capture(SessionConnectionSheet(model:draft,dismiss:{}),name:"session-connection-options" + (dark ? "-dark" : ""),directory:directory,dark:dark) {}
        draft.stop()
      }
      try await optionsSession.close(); try await optionsRuntime.shutdown()
      let securityRuntime = try NativeRuntime(), securitySession = try securityRuntime.makeSession()
      for dark in [false,true] {
        let draft = try NativeSessionSecurityDraft(session:securitySession); draft.reload()
        draft.preferences.types = "VncAuth"
        try await capture(SessionSecuritySheet(model:draft,dismiss:{}),name:"session-security" + (dark ? "-dark" : ""),directory:directory,dark:dark) {}
        await draft.close()
      }
      try await securitySession.close(); try await securityRuntime.shutdown()
      let choices = try NativeSecuritySelection.choices(), inherited = try NativeSecuritySelection()
      for dark in [false,true] {
        for fixture in ["inherited","custom","default","unavailable"] {
          let patch = NativeSecurityPreferences(tlsPriority:fixture == "inherited" ? nil : fixture == "custom" ? "NORMAL:-VERS-ALL:+VERS-TLS1.2" : "")
          try await capture(TLSPrioritySettingsFields(patch:.constant(patch),inheritedPriority:"NORMAL",inheritance:"Use app defaults",available:fixture != "unavailable").frame(width:560).padding(24),
            name:"tls-priority-" + fixture + (dark ? "-dark" : ""),directory:directory,dark:dark,size:NSSize(width:640,height:350)) {}
        }
        try await capture(SecuritySettingsFields(patch:.constant(.init(types: inherited.canonical)),inherited:inherited,choices:choices,inheritance:"Use built-in defaults").frame(width:560).padding(24),
          name:"security-all-methods" + (dark ? "-dark" : ""),directory:directory,dark:dark,size:NSSize(width:640,height:1600)) {}
      }

      for dark in [false, true] {
        for fixture in ["defaults", "conflict", "encoding", "encoding-manual", "input-defaults", "input-overrides", "input-off", "input-conflict", "scaling-defaults", "scaling-custom", "scaling-invalid", "scaling-conflict", "trust-defaults", "trust-files", "trust-invalid", "security-defaults", "security-custom", "security-empty", "security-invalid", "connection-defaults", "connection-custom", "fullscreen-defaults", "fullscreen-selected", "fullscreen-invalid", "resize-defaults", "resize-custom", "resize-server", "resize-invalid"] {
          let conflict = fixture == "conflict" || fixture == "input-conflict" || fixture == "scaling-conflict"
          // Closing the real view cancels edits. Use independent fixtures so
          // one appearance's lifecycle cannot reset another appearance's state.
          let store = NativePreferencesStore(backing: SettingsBacking()), model = NativePreferencesDraft(store: store)
          model.reload(); try await waitForDraft(model)
          if conflict {
            let initial = try await store.read()
            _ = try await store.commit(NativePreferences(clipboardSend: false), expected: initial.revision)
            model.values.clipboardReceive = false; model.apply(); try await waitForDraft(model)
            guard model.error == .conflict else { throw Failure(message: "Missing conflict presentation") }
          }
          if ["input-overrides", "input-off"].contains(fixture) {
            var patch = NativeInputPreferences(); patch.viewOnly = true; patch.emulateMiddle = true
            patch.fullscreenSystemKeys = false; patch.shortcutModifiers = fixture == "input-off" ? 0 : 15
            patch.cursorFallback = .system; model.values.input = patch
          }
          if ["scaling-custom", "scaling-invalid"].contains(fixture) {
            var patch = NativeScalingPreferences(); patch.scaling = fixture == "scaling-invalid" ? "1x0" : "125.00%x80.00%"
            patch.devicePixels = true; patch.filter = "area"; model.values.scaling = patch
            if fixture == "scaling-invalid" && model.canApply { throw Failure(message: "Invalid saved sizing remains applicable") }
          }
          if fixture == "trust-files" || fixture == "trust-invalid" {
            model.values.trustFiles = NativeTrustFiles(caFile: fixture == "trust-invalid" ? "relative.pem" : "/Users/fixture/Certificate Authorities/开发 lab.pem", crlFile: "")
            if fixture == "trust-invalid" && model.canApply { throw Failure(message: "Invalid trust path remains applicable") }
          }
          if fixture == "fullscreen-selected" { model.values.fullscreen = .init(startsFullscreen:true,mode:"selected",selectedDisplays:["missing-display"]) }
          if fixture == "fullscreen-invalid" {
            model.values.fullscreen = .init(mode:"selected",selectedDisplays:[])
            if model.canApply { throw Failure(message:"empty fullscreen selection enabled Apply") }
          }
          if fixture == "resize-custom" { model.values.remoteResize = .init(enabled:false,initialSize:"1920x1080") }
          if fixture == "resize-server" { model.values.remoteResize = .init(enabled:true,initialSize:"") }
          if fixture == "resize-invalid" {
            model.values.remoteResize = .init(initialSize:"65536x1080")
            if model.canApply { throw Failure(message:"invalid resize defaults enabled Apply") }
          }
          if fixture == "connection-custom" { model.values.shared = true; model.values.reconnectOnError = false }
          if fixture.hasPrefix("security-") && fixture != "security-defaults" {
            model.values.security = NativeSecurityPreferences(types: fixture == "security-empty" ? "" : fixture == "security-invalid" ? "Unknown" : "VncAuth,Plain")
            if fixture == "security-invalid" && model.canApply { throw Failure(message: "Invalid security remains applicable") }
          }
          if fixture == "encoding-manual" {
            model.setEncoding(.autoSelect, value: "off"); model.setEncoding(.preferred, value: "Raw")
            model.setEncoding(.fullColor, value: "off"); model.setEncoding(.lowColorLevel, value: "1")
            model.setEncoding(.customCompression, value: "on"); model.setEncoding(.compression, value: "9")
            model.setEncoding(.quality, value: "3")
            guard model.hasChanges && model.error == nil else { throw Failure(message: "Missing manual encoding fixture") }
          }
          try await render(model, name: ((fixture.hasPrefix("input-") || fixture.hasPrefix("scaling-")) ? "preferences-" : "") + fixture + (dark ? "-dark" : ""), directory: directory, dark: dark,
            section: fixture.hasPrefix("fullscreen-") ? .fullscreen : fixture.hasPrefix("resize-") ? .remoteResize : fixture.hasPrefix("connection-") ? .connection : fixture.hasPrefix("encoding") ? .encoding : fixture.hasPrefix("input-") ? .input : fixture.hasPrefix("scaling-") ? .scaling : fixture.hasPrefix("trust-") ? .trust : fixture.hasPrefix("security-") ? .security : .clipboard)
          if conflict && model.error != .conflict { throw Failure(message: "Conflict lost during rendering") }
          await model.close(); await store.close()
        }
      }
    } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
