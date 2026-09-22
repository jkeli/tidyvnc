// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import TidyVNCNative

@MainActor enum TidyVNCLaunchContext {
  static var startup = NativeInvocationStartup()
}

struct TidyVNCApp: App {
  @NSApplicationDelegateAdaptor(AppCoordinator.self) private var coordinator
  var body: some Scene {
    WindowGroup("TidyVNC", id: "connection") { StartupRoot(coordinator: coordinator) }
      .defaultSize(width: 960, height: 700)
      .commands { ConnectionCommands(coordinator: coordinator) }
    WindowGroup("TidyVNC", id: "profile-connection", for: ProfileConnectionRequest.self) { $request in
      if let request { ConnectionRoot(coordinator: coordinator, profileID: request.profileID) }
    }.defaultSize(width: 960, height: 700)
    WindowGroup("Connection File", id: "document-connection", for: NativeDocumentOpenRequest.self) { $request in
      if let request {
        ConnectionRoot(coordinator:coordinator,document:request)
          .navigationTitle(request.url.lastPathComponent)
      }
    }.defaultSize(width:960,height:700)
    Window("Saved Profiles", id: "profiles") {
      if let library = coordinator.profileLibrary { ProfileLibraryRoot(model: library) }
      else { Text("Saved profiles are unavailable.").padding(24) }
    }
    Window("Saved Server Keys", id: "server-keys") {
      if let library = coordinator.hostKeyLibrary { TrustLibraryView(model: library) }
    }
    Window("Saved Certificate Decisions", id: "trust-decisions") {
      if let library = coordinator.trustLibrary { TrustLibraryView(model: library) }
    }
    Settings {
      if let settings = coordinator.settings { PreferencesSettingsView(model: settings) }
      else { Text("Saved defaults are unavailable.").padding(24) }
    }
  }
}

@MainActor final class AppCoordinator: NSObject, NSApplicationDelegate, ObservableObject {
  private var runtime: NativeRuntime?
  private let clipboard = NativeClipboardCoordinator()
  let displays = NativeDisplayService()
  private let credentials = NativeCredentialStore()
  private let trustStore: NativeLegacyTrustStore?
  private let savedTrust = NativeTrustStore()
  private let savedHostKeys = NativeTrustStore(kind: .hostKey)
  private(set) var hostKeyLibrary: NativeTrustLibrary?
  private(set) var trustLibrary: NativeTrustLibrary?
  private var preferences: NativePreferencesStore?
  private var historyImportService: NativeHistoryImportService?
  private var historyImportWindow: HistoryImportWindowController?
  private var defaultsImportService: NativeDefaultsImportService?
  private var defaultsImportWindow: DefaultsImportWindowController?
  private(set) var importAvailability: DefaultsImportAvailability?
  private let profiles: NativeProfileHistoryStore
  let history: NativeRecentHistory
  private(set) var settings: NativePreferencesDraft?
  private(set) var profileLibrary: NativeProfileLibrary?
  private var startupError: String?
  private struct Entry { weak var window: NSWindow?; let model: ConnectionModel }
  private var windows: [ObjectIdentifier: Entry] = [:]
  private var quitting = false
  private var readyToTerminate = false
  private var terminationReplyPending = false
  private var documentSavePanels: [ObjectIdentifier:NSSavePanel] = [:]
  private var documentPanel: NSOpenPanel?
  private var listenerWindow: ListenerWindowController?
  private var startupListener: ListenerModel?
  private weak var startupListenerWindow: NSWindow?
  private var startupListenerCleanup: Task<Void,Never>?
  private var reverseWindows: [ObjectIdentifier:NSWindowController] = [:]
  private let documentLaunch = NativeDocumentLaunchRouter()
  private let invocationStartup = TidyVNCLaunchContext.startup
  private var activeObservation: AnyCancellable?
  @Published var active: ConnectionModel? {
    didSet {
      activeObservation = active?.objectWillChange.sink { [weak self] in
        MainActor.assumeIsolated { self?.objectWillChange.send() }
      }
    }
  }
  override init() {
    let profiles = NativeProfileHistoryStore(backing: NativeApplicationSupportProfiles())
    trustStore = (try? NativeLegacyTrustFile.applicationStore()).map { NativeLegacyTrustStore(backing: $0) }
    self.profiles = profiles; history = NativeRecentHistory(store: profiles)
    super.init()
    trustLibrary = NativeTrustLibrary(store: savedTrust)
    hostKeyLibrary = NativeTrustLibrary(store: savedHostKeys)
    history.reload()
    clipboard.setApplicationActive(NSApp?.isActive == true)
    let environment = NativePathEnvironment.capture()
    let importPaths = try? NativeImportPaths(homeDirectory:environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                                            environment:environment)
    if let importPaths { historyImportService = NativeHistoryImportService(paths:importPaths,store:profiles) }
    do {
      runtime = try NativeRuntime()
      let store = NativePreferencesStore(backing: try UserDefaultsPreferencesBacking())
      preferences = store; settings = NativePreferencesDraft(store: store)
      importAvailability = DefaultsImportAvailability(store:store)
      if let paths = importPaths {
        defaultsImportService = NativeDefaultsImportService(paths:paths,store:store)
      }
      profileLibrary = NativeProfileLibrary(store: profiles, preferences: store)
    } catch { startupError = String(describing: error) }
  }
  func takeInvocation() -> NativeInvocationLaunch? { invocationStartup.take() }
  func makeConnection(profileID: UUID? = nil, document: NativeDocumentOpenRequest? = nil, launch: NativeInvocationLaunch? = nil) -> ConnectionModel {
    guard let runtime, let preferences, !quitting else { return ConnectionModel(error: startupError ?? "The application is closing.") }
    return ConnectionModel(runtime: runtime, preferences: preferences, displays: displays, history: history, profileStore: profiles, profileID: profileID,
      document:document ?? launch?.document,invocation:launch?.invocation,connectOnReady:launch?.connectsOnReady == true,launchCredentials:launch?.credentials,credentialStore: credentials, trustStore: trustStore, savedTrustStore: savedTrust,hostKeyStore: savedHostKeys) { [weak self] session, model in
      model.fullscreen.onActivate = { [weak self, weak model] in if let model { self?.active = model } }
      self?.clipboard.register(session) { [weak model] status in model?.clipboardMessage = status }
    }
  }
  func showListener() {
    guard !quitting, let runtime else { return }
    if let window = startupListenerWindow, startupListener?.closing == false { window.makeKeyAndOrderFront(nil); return }
    if let listenerWindow { listenerWindow.showWindow(nil); return }
    let model = ListenerModel(runtime:runtime) { [weak self] request in self?.openIncoming(request) == true }
    let controller = ListenerWindowController(model:model,onActivate:{ [weak self] in self?.active = nil }) { [weak self] closed in
      if self?.listenerWindow === closed { self?.listenerWindow = nil }
    }
    listenerWindow = controller; controller.showWindow(nil)
  }
  func makeStartupListener(_ launch: NativeInvocationLaunch) -> ListenerModel? {
    guard !quitting, let runtime, launch.listen != nil else { launch.credentials?.clear(); return nil }
    let model = ListenerModel(runtime:runtime,launch:launch,preferences:preferences,displays:displays) { [weak self] request in self?.openIncoming(request) == true }
    startupListener = model; return model
  }
  func registerListener(_ window: NSWindow, model: ListenerModel) {
    guard startupListener === model, startupListenerWindow !== window, !quitting else { return }
    startupListenerWindow = window
    window.setContentSize(NSSize(width:700,height:560)); window.minSize = NSSize(width:660,height:500)
    NotificationCenter.default.addObserver(self,selector:#selector(startupListenerClosed(_:)),name:NSWindow.willCloseNotification,object:window)
    NotificationCenter.default.addObserver(self,selector:#selector(windowActivated(_:)),name:NSWindow.didBecomeKeyNotification,object:window)
    if window.isKeyWindow { active = nil }
  }
  @objc private func startupListenerClosed(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, startupListenerWindow === window, let model = startupListener else { return }
    NotificationCenter.default.removeObserver(self,name:NSWindow.willCloseNotification,object:window)
    NotificationCenter.default.removeObserver(self,name:NSWindow.didBecomeKeyNotification,object:window)
    startupListenerWindow = nil; startupListener = nil; model.requestClose()
    startupListenerCleanup = Task { await model.close() }
  }
  private func openIncoming(_ request: ReverseConnectionRequest) -> Bool {
    guard !quitting, let runtime, let preferences else { return false }
    let model = ConnectionModel(runtime:runtime,preferences:preferences,displays:displays,reverse:request) { [weak self] session, model in
      model.fullscreen.onActivate = { [weak self, weak model] in if let model { self?.active = model } }
      self?.clipboard.register(session) { [weak model] status in model?.clipboardMessage = status }
    }
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:700),
      styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    window.title = "Incoming Connection"; window.isReleasedWhenClosed = false
    let content = NSHostingController(rootView:ConnectionRoot(coordinator:self,model:model)); content.sizingOptions = []
    window.contentViewController = content
    window.setContentSize(NSSize(width:960,height:700)); window.minSize = NSSize(width:640,height:420)
    let controller = NSWindowController(window:window); reverseWindows[ObjectIdentifier(window)] = controller
    register(window,model:model); window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
    return true
  }
  func showDefaultsImport(_ openConnection: @escaping @MainActor () -> Void) {
    guard !quitting else { return }
    if let defaultsImportWindow { defaultsImportWindow.showWindow(nil); return }
    guard let defaultsImportService else {
      let alert = NSAlert()
      alert.messageText = "Defaults import is unavailable"
      alert.informativeText = "Check the native settings store and the home/XDG configuration paths, then reopen the app."
      alert.runModal(); return
    }
    let controller = DefaultsImportWindowController(service:defaultsImportService,displays:{ [displays] in
      displays.refresh(); return displays.snapshot
    },openConnection:openConnection,onClosed:{ [weak self] closed in
      if self?.defaultsImportWindow === closed { self?.defaultsImportWindow = nil }
    })
    defaultsImportWindow = controller; controller.showWindow(nil)
  }
  func showHistoryImport() {
    guard !quitting else { return }
    if let historyImportWindow { historyImportWindow.showWindow(nil); return }
    guard let historyImportService else {
      let alert = NSAlert()
      alert.messageText = "History import is unavailable"
      alert.informativeText = "Check the home/XDG paths, then reopen the app."
      alert.runModal(); return
    }
    let controller = HistoryImportWindowController(service:historyImportService,reloadHistory:{ [history] in
      history.reload()
    },onClosed:{ [weak self] closed in
      if self?.historyImportWindow === closed { self?.historyImportWindow = nil; self?.history.reload() }
    })
    historyImportWindow = controller; controller.showWindow(nil)
  }
  func openDocument(_ open: @escaping @MainActor (NativeDocumentOpenRequest) -> Void) {
    guard !quitting, documentPanel == nil else { return }
    let panel = NSOpenPanel()
    panel.title = "Open Connection File"; panel.prompt = "Review"
    panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    documentPanel = panel
    panel.begin { [weak self, weak panel] result in
      guard let self, let panel, self.documentPanel === panel else { return }
      self.documentPanel = nil
      guard !self.quitting, result == .OK, let url = panel.url else { return }
      open(NativeDocumentOpenRequest(url:url))
    }
  }
  func showDocumentSavePanel(_ model: ConnectionModel) {
    let key = ObjectIdentifier(model)
    guard !quitting, !model.closing, let id = model.documentSave.choosing, documentSavePanels[key] == nil else { return }
    guard let window = windows.values.first(where:{ $0.model === model })?.window,
          let type = UTType(filenameExtension:"tidyvnc",conformingTo:.data) else {
      model.documentSave.cancel(id); return
    }
    let panel = NSSavePanel()
    panel.title = "Save Connection File"; panel.prompt = "Save"
    panel.allowedContentTypes = [type]; panel.allowsOtherFileTypes = false
    panel.isExtensionHidden = false; panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Connection"
    documentSavePanels[key] = panel
    panel.beginSheetModal(for:window) { [weak self, weak model, weak panel] response in
      guard let self, let panel, self.documentSavePanels[key] === panel else { return }
      self.documentSavePanels.removeValue(forKey:key)
      guard let model, !self.quitting, !model.closing, model.documentSave.choosing == id else { return }
      guard response == .OK, let url = panel.url else { model.documentSave.cancel(id); return }
      // NSSavePanel's OK includes its explicit existing-file replacement prompt.
      model.documentSave.choose(url,id:id,overwrite:true)
    }
  }
  func installDocumentRouting(_ open: @escaping @MainActor (NativeDocumentOpenRequest) -> Void) {
    documentLaunch.install(open)
  }
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    // Success means accepted into the review flow, not validated or connected.
    // File read/semantic errors are presented in their individual review windows.
    sender.reply(toOpenOrPrint: documentLaunch.route(filePaths:filenames) ? .success : .failure)
  }
  func application(_ sender: NSApplication, open urls: [URL]) {
    // Modern AppKit/SwiftUI delivery prefers this callback over openFiles.
    // This application declares document types, not network URL schemes.
    sender.reply(toOpenOrPrint: documentLaunch.route(urls:urls) ? .success : .failure)
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    clipboard.setApplicationActive(true); history.reload(); importAvailability?.refresh()
  }
  func applicationDidResignActive(_ notification: Notification) { clipboard.setApplicationActive(false) }
  func register(_ window: NSWindow, model: ConnectionModel) {
    let id = ObjectIdentifier(window); guard windows[id] == nil else { return }
    windows[id] = Entry(window: window, model: model)
    model.fullscreen.windowStartup.attach(window)
    NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)), name: NSWindow.willCloseNotification, object: window)
    NotificationCenter.default.addObserver(self, selector: #selector(windowActivated(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
    if window.isKeyWindow { active = model }
  }
  @objc private func windowActivated(_ notification: Notification) {
    if let window = notification.object as? NSWindow { active = windows[ObjectIdentifier(window)]?.model }
  }
  @objc private func windowClosed(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
    NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
    documentSavePanels.removeValue(forKey:ObjectIdentifier(entry.model))?.cancel(nil)
    if active === entry.model { active = nil }
    if let session = entry.model.session { clipboard.unregister(session) }
    reverseWindows.removeValue(forKey:ObjectIdentifier(window))
    // SwiftUI may destroy the window immediately. The cleanup task owns only
    // the session until drain, and its native callback routing is invalidated first.
    entry.model.requestClose()
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if readyToTerminate { return .terminateNow }
    terminationReplyPending = true
    requestQuit()
    return .terminateLater
  }
  func requestQuit() {
    guard !quitting else { return }
    quitting = true
    historyImportWindow?.state.stop()
    defaultsImportWindow?.state.stop(); importAvailability?.stop()
    documentLaunch.stop(); invocationStartup.stop()
    listenerWindow?.model.requestClose()
    startupListener?.requestClose()
    let savePanels = Array(documentSavePanels.values); documentSavePanels.removeAll()
    for panel in savePanels { panel.cancel(nil) }
    documentPanel?.cancel(nil); documentPanel = nil
    clipboard.stop()
    displays.stop()
    settings?.stop(); history.stop(); profileLibrary?.stop(); trustLibrary?.stop(); hostKeyLibrary?.stop()
    let models = windows.values.map(\.model)
    for model in models { model.requestClose() }
    let owner = runtime
    Task { @MainActor in
      try? await owner?.shutdown()
      for model in models { await model.close() }
      await listenerWindow?.shutdown()
      await startupListener?.close(); await startupListenerCleanup?.value
      await historyImportWindow?.shutdown()
      await defaultsImportWindow?.shutdown(); await importAvailability?.close()
      await settings?.close()
      await profileLibrary?.close(); await trustLibrary?.close(); await hostKeyLibrary?.close()
      await preferences?.close()
      await history.close(); await profiles.close()
      await credentials.close(); await trustStore?.close(); await savedTrust.close(); await savedHostKeys.close()
      await clipboard.close()
      windows.removeAll(); reverseWindows.removeAll(); active = nil
      readyToTerminate = true
      if terminationReplyPending { NSApp.reply(toApplicationShouldTerminate: true) }
      else { NSApp.terminate(nil) }
    }
  }
}

// StateObject constructs this owner once per scene. Only the first ordinary
// scene consumes argv; Finder/profile scenes never compete for launch ownership.
@MainActor private final class StartupPresentation: ObservableObject {
  enum Content { case connection(ConnectionModel), listener(ListenerModel) }
  let content: Content
  init(coordinator: AppCoordinator) {
    let launch = coordinator.takeInvocation()
    if let launch, launch.listen != nil, let model = coordinator.makeStartupListener(launch) {
      content = .listener(model)
    } else { content = .connection(coordinator.makeConnection(launch:launch)) }
  }
}
private struct StartupRoot: View {
  let coordinator: AppCoordinator
  @Environment(\.openWindow) private var openWindow
  @StateObject private var startup: StartupPresentation
  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator; _startup = StateObject(wrappedValue:StartupPresentation(coordinator:coordinator))
  }
  var body: some View {
    switch startup.content {
    case .connection(let model): ConnectionRoot(coordinator:coordinator,model:model)
    case .listener(let model):
      ListenerView(model:model).navigationTitle("Listen for Connections")
        .background(ListenerRegistration(coordinator:coordinator,model:model).frame(width:0,height:0))
        .onAppear {
          let action = openWindow
          coordinator.installDocumentRouting { action(id:"document-connection",value:$0) }
          model.startLaunchIfNeeded()
        }
    }
  }
}

private struct ConnectionCommands: Commands {
  @ObservedObject var coordinator: AppCoordinator
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    // A SwiftUI authentication sheet can defer the standard termination action.
    // Cancel and dismiss our requests before asking AppKit to terminate.
    CommandGroup(replacing: .appTermination) {
      Button("Quit TidyVNC") { coordinator.requestQuit() }.keyboardShortcut("q")
    }
    CommandGroup(replacing: .newItem) {
      Button("New Connection") { openWindow(id: "connection") }.keyboardShortcut("n")
      Button("Listen for Connections…") { coordinator.showListener() }.keyboardShortcut("l",modifiers:[.command,.shift])
      Button("Open Connection File…") {
        coordinator.openDocument { openWindow(id:"document-connection",value:$0) }
      }.keyboardShortcut("o")
      Button("Save Connection File As…") { coordinator.active?.beginDocumentExport() }
        .keyboardShortcut("s",modifiers:[.command,.shift])
        .disabled(coordinator.active?.canExportDocument != true)
      Divider()
      Button("Import Connection Defaults…") { coordinator.showDefaultsImport { openWindow(id:"connection") } }
      Button("Import Recent Connections…") { coordinator.showHistoryImport() }
      Divider()
      Button("Saved Server Keys…") { openWindow(id: "server-keys") }
      Button("Saved Certificate Decisions…") { openWindow(id: "trust-decisions") }
      Button("Saved Profiles…") { openWindow(id: "profiles") }.keyboardShortcut("p", modifiers: [.command, .shift])
    }
    CommandMenu("Connection") {
      if let model = coordinator.active { DesktopActions(model: model) }
      else { Text("No active connection") }
    }
  }
}

private struct ConnectionRoot: View {
  let coordinator: AppCoordinator
  @Environment(\.openWindow) private var openWindow
  @StateObject private var model: ConnectionModel
  init(coordinator: AppCoordinator, profileID: UUID? = nil, document: NativeDocumentOpenRequest? = nil) { self.coordinator = coordinator; _model = StateObject(wrappedValue: coordinator.makeConnection(profileID: profileID,document:document)) }
  init(coordinator: AppCoordinator, model: ConnectionModel) { self.coordinator = coordinator; _model = StateObject(wrappedValue:model) }
  var body: some View {
    Group {
      if let session = model.session {
        ConnectionContent(model:model,session:session,displays:coordinator.displays,importAvailability:coordinator.importAvailability,
          openImport:{ coordinator.showDefaultsImport { openWindow(id:"connection") } },
          openHistoryImport:{ coordinator.showHistoryImport() })
      }
      else if let defaults = model.defaults {
        VStack(spacing: 16) {
          if let mapping = defaults.invocationMapping {
            InvocationMonitorMappingView(mapping:mapping,displays:coordinator.displays,issue:defaults.invocationIssue,
              resolve:{ defaults.resolveInvocationMapping(mapping.id,assignments:$0) },
              cancel:{ defaults.cancelInvocationMapping(mapping.id) }).id(mapping.id)
          } else if let mapping = defaults.documentMapping {
            DocumentMonitorMappingView(mapping:mapping,displays:coordinator.displays,issue:defaults.documentIssue,
              resolve:{ defaults.resolveDocumentMapping(mapping.id,assignments:$0) },
              cancel:{ defaults.cancelDocumentMapping(mapping.id) }).id(mapping.id)
          } else if let review = defaults.documentReview {
            DocumentReviewView(review:review,displays:coordinator.displays,
              editMapping:{ defaults.editDocumentMapping(review.id) },
              accept:{ defaults.acceptDocument(review.id) },cancel:{ defaults.cancelDocument(review.id) })
          } else if let issue = defaults.invocationIssue {
            Text(issue).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("invocation.error")
            Button("Retry Command-Line Options") { defaults.load() }
              .accessibilityIdentifier("invocation.retry")
          } else if let issue = defaults.documentIssue {
            Text(issue).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("document.error")
            Button("Reload Connection File") { defaults.load() }
          } else if let error = defaults.profileError {
            Text(profileMessage(error)).fixedSize(horizontal: false, vertical: true)
            Button("Retry Profile") { defaults.load() }
          } else if let error = defaults.error {
            Text(preferencesMessage(error)).fixedSize(horizontal: false, vertical: true)
            Button("Retry Defaults") { defaults.load() }
            Button("Use Built-in Defaults for This Connection") { defaults.useBuiltInDefaults() }
          } else { ProgressView("Loading connection defaults…") }
        }.padding(24)
      }
      else { ContentUnavailableView("Unable to start a connection", systemImage: "exclamationmark.triangle", description: Text(model.message ?? "Please try again.")) }
    }
    .sheet(item:Binding(get:{ model.documentSave.presentation },set:{ value in
      if value == nil, let id = model.documentSave.presentation?.id { model.documentSave.cancelPresentation(id) }
    }),onDismiss:{ coordinator.showDocumentSavePanel(model) }) { _ in
      DocumentSaveReviewView(state:model.documentSave)
    }
    .overlay(alignment:.bottomLeading) {
      if model.documentSave.isWriting || model.documentSave.issue != nil || model.documentSave.savedURL != nil {
        DocumentSaveStatusView(state:model.documentSave)
          .background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).padding(12)
      }
    }
    .frame(minWidth: 640, minHeight: 420)
    .navigationTitle(model.isReverse ? "Incoming Connection" : model.defaults?.documentRequest?.url.lastPathComponent ?? "TidyVNC")
    .onAppear {
      guard !model.isReverse else { return }
      // Capture only the scene action, not this root or its connection model.
      let action = openWindow
      coordinator.installDocumentRouting { action(id:"document-connection",value:$0) }
    }
    .background(WindowRegistration(coordinator: coordinator, model: model).frame(width: 0, height: 0))
  }
}

private struct ConnectionContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var model: ConnectionModel
  @ObservedObject var session: NativeSession
  let displays: NativeDisplayService
  let importAvailability: DefaultsImportAvailability?
  let openImport: () -> Void
  let openHistoryImport: () -> Void
  var body: some View {
    let visibleSheet = presentedSheet
    let problem = model.connectionProblem
    VStack(spacing: 0) {
      if !model.isReverse, session.snapshot.state == .idle, model.defaults?.profile == nil, model.defaults?.documentRequest == nil,
         !model.busy {
        if let importAvailability { FirstUseDefaultsImportOffer(availability:importAvailability,open:openImport) }
        if let history = model.history { FirstUseHistoryImportOffer(history:history,open:openHistoryImport) }
      }
      HStack(spacing: 12) {
        Image(systemName: "display").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField("Server address", text: $model.endpoint).textFieldStyle(.roundedBorder)
          .help(model.isReverse ? "Source address of this incoming connection; it is not an outbound destination." : "Enter host:display, host::port, [IPv6]:display, or a Unix socket path.")
          .accessibilityIdentifier("connection.endpoint").disabled(model.isReverse || model.busy || session.snapshot.state == .connected)
          .onSubmit { model.connect() }
        if let history = model.history {
          RecentConnectionsButton(model: history, canSelect: !model.busy && session.snapshot.state != .connected) { model.endpoint = $0 }
        }
        if !model.isReverse { Button { openWindow(id: "profiles") } label: { Image(systemName: "folder") }
          .help("Saved profiles").accessibilityLabel("Saved profiles").accessibilityIdentifier("connection.profiles")
        }
        Menu {
          Toggle("Send clipboard to server", isOn: Binding(get: { session.clipboardSendEnabled }, set: { setClipboard(send: $0) }))
            .accessibilityIdentifier("clipboard.send")
          Toggle("Receive clipboard from server", isOn: Binding(get: { session.clipboardReceiveEnabled }, set: { setClipboard(receive: $0) }))
            .accessibilityIdentifier("clipboard.receive")
          if let defaults = model.defaults {
            Divider()
            Text("Send: \(source(defaults.overrides.clipboardSend, defaults.profile?.settings.clipboardSend, defaults.inherited.clipboardSend, document:defaults.documentResolution?.fieldLines["SendClipboard"] != nil))")
            Text("Receive: \(source(defaults.overrides.clipboardReceive, defaults.profile?.settings.clipboardReceive, defaults.inherited.clipboardReceive, document:defaults.documentResolution?.fieldLines["AcceptClipboard"] != nil))")
          }
        } label: { Image(systemName: "doc.on.clipboard") }
          .fixedSize().help("Clipboard sharing for this connection").accessibilityLabel("Clipboard sharing")
          .accessibilityIdentifier("clipboard.options")
          .disabled(model.defaults?.isReady != true)
        Menu { DesktopActions(model: model) } label: { Image(systemName: "ellipsis.circle") }
          .fixedSize().help("Connection actions").accessibilityLabel("Connection actions")
          .accessibilityIdentifier("connection.actions")
        Button { model.openInput() } label: { Image(systemName: "keyboard") }
          .disabled(!model.canOpenInput).help("Input settings for this connection")
          .accessibilityLabel("Input settings").accessibilityIdentifier("connection.input")
        Button { model.openScaling() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
          .disabled(!model.canOpenScaling).help("Scaling settings for this connection")
          .accessibilityLabel("Scaling settings").accessibilityIdentifier("connection.scaling")
        Button { model.openEncoding() } label: { Image(systemName: "slider.horizontal.3") }
          .disabled(!model.canOpenEncoding).help("Encoding settings for this connection")
          .accessibilityLabel("Encoding settings").accessibilityIdentifier("connection.encoding")
        if model.busy {
          ProgressView().controlSize(.small)
          Button("Cancel") { model.cancel() }.accessibilityIdentifier("connection.cancel")
        } else if session.snapshot.state == .connected {
          Button("Disconnect") { model.disconnect() }.accessibilityIdentifier("connection.disconnect")
        } else if !model.isReverse {
          Button("Connect") { model.connect() }.disabled(!model.canConnect).keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("connection.connect")
        }
      }.padding(14)
      EndpointIssueView(issue: model.endpointIssue).padding(.horizontal, 14)
      if model.isReverse {
        Text("Incoming connection. To reconnect, ask the server to connect to the listener again. Passwords, trust decisions and this temporary address are not saved.")
          .font(.caption).foregroundStyle(.secondary).padding(.horizontal,14).padding(.bottom,8)
          .accessibilityIdentifier("connection.reverse")
      }
      if let history = model.history { RecentHistoryStatus(model: history).padding(.horizontal, 14) }
      if let profile = model.defaults?.profile {
        Text("Settings from profile: \(profile.name)").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
      }
      if let notice = model.credentials.notice {
        HStack {
          Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button("Dismiss") { model.credentials.dismissNotice() }
        }.padding(.horizontal, 14).padding(.vertical, 8).accessibilityIdentifier("credentials.notice")
      }
      Divider()
      ZStack {
        NativeDesktop(session: session, displays: displays, scaling: model.scaling, input: model.input, commands: model.desktopCommands, fullscreen: model.fullscreen, onContextMenu: { view in
          let popup = DesktopContextMenu(model: model)
          withExtendedLifetime(popup) { popup.show(in: view) }
        }) { model.message = $0 }
        if !session.hasFrame {
          ContentUnavailableView(session.snapshot.state == .idle ? "Connect to a desktop" : status,
            systemImage: "display", description: Text(session.snapshot.state == .idle ? "Enter a VNC server address to begin." : ""))
            .allowsHitTesting(false)
        }
      }.overlay(alignment: .topTrailing) {
        if model.showsStatistics, let information = session.information {
          ConnectionStatisticsOverlay(information: information).padding(12)
        }
      }.clipped()
      Divider()
      HStack {
        Text(status).accessibilityIdentifier("connection.status")
        Spacer()
        if let message = model.fullscreen.message {
          Text(message).foregroundStyle(.orange).lineLimit(1).help(message).accessibilityIdentifier("fullscreen.status")
        }
        if let message = model.desktopCommands.windowMessage {
          Text(message).foregroundStyle(.orange).lineLimit(1).help(message).accessibilityIdentifier("window.commandStatus")
        }
        if model.desktopCommands.keyboardCaptured {
          Text("Keyboard captured").accessibilityIdentifier("keyboard.captured")
        } else if let message = model.desktopCommands.captureMessage {
          Text(message).foregroundStyle(.orange).lineLimit(1).help(message).accessibilityIdentifier("keyboard.captureStatus")
        }
        if let message = session.remoteResize.message {
          Text(message).foregroundStyle(.orange).lineLimit(1).help(message).accessibilityIdentifier("remoteResize.status")
        }
        if let message = model.clipboardMessage {
          Text(message).foregroundStyle(.orange).lineLimit(1).help(message).accessibilityIdentifier("clipboard.status")
        }
        if session.snapshot.width > 0 { Text("\(session.snapshot.width) × \(session.snapshot.height)").monospacedDigit() }
      }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
    }
    .sheet(item: Binding(get: { visibleSheet }, set: { value in
      // Dismiss only the editor that created this binding. A delayed dismissal
      // must not cancel a newer editor or an authentication prompt.
      guard value == nil, session.prompt == nil else { return }
      switch visibleSheet {
      case .fullscreen(let draft) where model.fullscreenDraft === draft: model.closeFullscreen()
      case .resizePolicy(let draft) where model.resizePolicyDraft === draft: model.closeResizePolicy()
      case .remoteResize(let draft) where model.remoteResizeDraft === draft: model.closeRemoteResize()
      case .connectionOptions(let draft) where model.connectionOptionsDraft === draft: model.closeConnectionOptions()
      case .security(let draft) where model.securityDraft === draft: model.closeSecurity()
      case .encoding(let draft) where model.encodingDraft === draft: model.closeEncoding()
      case .information(let id) where model.informationID == id: model.closeInformation()
      case .input(let draft) where model.inputDraft === draft: model.closeInput()
      case .scaling(let draft) where model.scalingDraft === draft: model.closeScaling()
      default: break
      }
    })) { sheet in
      switch sheet {
      case .authentication(let request):
        AuthenticationSheet(model: model, session: session, request: request).interactiveDismissDisabled()
      case .information:
        ConnectionInformationSheet(endpoint: model.endpoint, session: session, dismiss: model.closeInformation)
      case .input(let draft):
        InputSettingsSheet(model: draft, dismiss: model.closeInput)
      case .scaling(let draft):
        ScalingSettingsSheet(model: draft, dismiss: model.closeScaling)
      case .fullscreen(let draft):
        FullscreenSettingsSheet(model:draft,dismiss:model.closeFullscreen)
      case .resizePolicy(let draft):
        RemoteResizePolicySheet(model:draft,dismiss:model.closeResizePolicy)
      case .remoteResize(let draft):
        RemoteResizeSheet(model:draft,dismiss:model.closeRemoteResize)
      case .connectionOptions(let draft):
        SessionConnectionSheet(model:draft,dismiss:model.closeConnectionOptions)
      case .security(let draft):
        SessionSecuritySheet(model:draft,dismiss:model.closeSecurity)
      case .encoding(let draft):
        SessionEncodingSheet(model: draft, dismiss: model.closeEncoding)
      }
    }
    .alert(problem?.issue.title ?? "Connection Problem", isPresented: Binding(
      get: { !model.documentSave.hasPending && model.fullscreen.phase == .windowed && (problem != nil || model.message != nil) },
      set: { visible in
        if !visible {
          if let problem { model.hideConnectionProblem(problem.id) }
          else { model.message = nil }
        }
      })) {
      if let problem {
        if model.offersRetryConnection(problem) {
          Button("Retry") { model.retryConnection(problem) }
            .disabled(!model.canRetryConnection(problem))
            .accessibilityIdentifier("connection.retry")
        }
        Button("Cancel", role: .cancel) { model.dismissConnectionProblem(problem.id) }
          .keyboardShortcut(.defaultAction)
      } else {
        Button("OK", role: .cancel) { model.message = nil }.keyboardShortcut(.defaultAction)
      }
    } message: {
      Text(problem?.issue.message ?? model.message ?? "")
    }
  }
  private enum Sheet: Identifiable {
    case fullscreen(NativeFullscreenDraft)
    case resizePolicy(NativeRemoteResizePolicyDraft)
    case remoteResize(NativeRemoteResizeDraft)
    case security(NativeSessionSecurityDraft), connectionOptions(NativeConnectionDraft)
    case authentication(NativePrompt), encoding(NativeSessionEncodingDraft), scaling(NativeScalingDraft), input(NativeInputDraft), information(UUID)
    var id: String {
      switch self {
      case .authentication(let request): return "authentication-\(request.generation)-\(request.id)"
      case .information(let id): return "information-\(id)"
      case .input(let draft): return "input-\(draft.id)"
      case .scaling(let draft): return "scaling-\(draft.id)"
      case .fullscreen(let draft): return "fullscreen-\(draft.id)"
      case .resizePolicy(let draft): return "resize-policy-\(draft.id)"
      case .remoteResize(let draft): return "remote-resize-\(draft.id)"
      case .connectionOptions(let draft): return "connection-options-\(draft.id)"
      case .security(let draft): return "security-\(draft.id)"
      case .encoding(let draft): return "encoding-\(draft.id)"
      }
    }
  }
  private var presentedSheet: Sheet? {
    if let prompt = session.prompt { return .authentication(prompt) }
    if let id = model.informationID { return .information(id) }
    if let draft = model.inputDraft { return .input(draft) }
    if let draft = model.fullscreenDraft { return .fullscreen(draft) }
    if let draft = model.resizePolicyDraft { return .resizePolicy(draft) }
    if let draft = model.remoteResizeDraft { return .remoteResize(draft) }
    if let draft = model.scalingDraft { return .scaling(draft) }
    if let draft = model.connectionOptionsDraft { return .connectionOptions(draft) }
    if let draft = model.securityDraft { return .security(draft) }
    if let draft = model.encodingDraft { return .encoding(draft) }
    return nil
  }
  private func setClipboard(send: Bool? = nil, receive: Bool? = nil) {
    do { try model.defaults?.setClipboard(send: send, receive: receive); model.clipboardMessage = nil }
    catch { model.clipboardMessage = "Clipboard settings could not be changed. Try again." }
  }
  private func source(_ override: Bool?, _ profile: Bool?, _ inherited: Bool?, document: Bool) -> String {
    override != nil ? "Connection override" : document ? "Connection file" : profile != nil ? "Profile" : inherited != nil ? "App default" : "Built-in default"
  }
  private var status: String {
    switch session.snapshot.state {
    case .idle: return "Ready"
    case .resolving: return "Resolving server…"
    case .connecting, .negotiating: return "Connecting…"
    case .authenticating: return "Waiting for authentication"
    case .connected: return "Connected"
    case .disconnecting: return "Disconnecting…"
    case .closed: return "Disconnected"
    case .failed: return "Connection failed"
    }
  }
}

private struct ListenerRegistration: NSViewRepresentable {
  let coordinator: AppCoordinator; let model: ListenerModel
  func makeNSView(context: Context) -> Attachment { Attachment(coordinator:coordinator,model:model) }
  func updateNSView(_ view: Attachment, context: Context) {}
  final class Attachment: NSView {
    let coordinator: AppCoordinator; let model: ListenerModel
    init(coordinator: AppCoordinator, model: ListenerModel) {
      self.coordinator = coordinator; self.model = model; super.init(frame:.zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { coordinator.registerListener(window,model:model) } }
  }
}
private struct WindowRegistration: NSViewRepresentable {
  let coordinator: AppCoordinator; let model: ConnectionModel
  func makeNSView(context: Context) -> Attachment { Attachment(coordinator: coordinator, model: model) }
  func updateNSView(_ view: Attachment, context: Context) {}
  final class Attachment: NSView {
    let coordinator: AppCoordinator; let model: ConnectionModel
    init(coordinator: AppCoordinator, model: ConnectionModel) {
      self.coordinator = coordinator; self.model = model; super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { coordinator.register(window, model: model) } }
  }
}
