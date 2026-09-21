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
    .environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
  let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
  window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  window.isReleasedWhenClosed = false; window.contentView = view
  defer { window.contentView = nil; window.close() }
  view.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(50)); try await ready()
  view.layoutSubtreeIfNeeded()
  let fitting = view.fittingSize
  guard fitting.width <= size.width, fitting.height <= size.height else { throw Failure(message: "Settings exceeds test window: \(fitting)") }
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "No settings bitmap") }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "No settings PNG") }
  try data.write(to: directory.appendingPathComponent(name + ".png"))
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
    for fixture in ["empty", "saved", "editing", "scaling", "resize", "resize-invalid", "invalid-address", "conflict", "error", "pending"] {
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
                        directory: directory, dark: dark, size: NSSize(width: 940, height: 680)) {
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
    try await capture(ConnectionInformationSheet(endpoint: "a-long-hostname.for-the-development-lab.example.internal::5902", session: session, dismiss: {}),
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
    func digest(_ algorithm: UInt32) throws -> Data { throw NativeTrustStoreIssue.unsupportedDigest }
  }
  let changed = try NativeLegacyTrustCodec.lookup(data: Data("|g0|fixture.invalid|*|0|BAUG\n".utf8),
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
@main struct NativeSettingsTests {
  @MainActor static func main() async {
    _ = NSApplication.shared
    do {
      let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
