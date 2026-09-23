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
    WindowGroup(Text(verbatim:"TidyVNC"), id: "connection") { StartupRoot(coordinator: coordinator) }
      .defaultSize(width: 960, height: 700)
      .commands { ConnectionCommands(coordinator: coordinator) }
    WindowGroup(Text(verbatim:"TidyVNC"), id: "profile-connection", for: ProfileConnectionRequest.self) { $request in
      if let request { ConnectionRoot(coordinator: coordinator, profileID: request.profileID) }
    }.defaultSize(width: 960, height: 700)
    WindowGroup(String(localized:"app.connection.file", defaultValue:"Connection File"), id: "document-connection", for: NativeDocumentOpenRequest.self) { $request in
      if let request {
        ConnectionRoot(coordinator:coordinator,document:request)
          .navigationTitle(request.url.lastPathComponent)
      }
    }.defaultSize(width:960,height:700)
    Window(String(localized:"profiles.saved.profiles", defaultValue:"Saved Profiles"), id: "profiles") {
      if let library = coordinator.profileLibrary { ProfileLibraryRoot(model: library) }
      else { Text(String(localized:"app.saved.profiles.are.unavailable", defaultValue:"Saved profiles are unavailable.")).padding(24) }
    }.defaultSize(width:940,height:680)
    Window(String(localized:"trust.library.ui.saved.server.keys", defaultValue:"Saved Server Keys"), id: "server-keys") {
      if let library = coordinator.hostKeyLibrary { TrustLibraryView(model: library) }
    }
    Window(String(localized:"trust.library.ui.saved.certificate.decisions", defaultValue:"Saved Certificate Decisions"), id: "trust-decisions") {
      if let library = coordinator.trustLibrary { TrustLibraryView(model: library) }
    }
    Settings {
      if let settings = coordinator.settings { PreferencesSettingsView(model: settings) }
      else { Text(String(localized:"app.saved.defaults.are.unavailable", defaultValue:"Saved defaults are unavailable.")).padding(24) }
    }
    Window(String(localized:"help.title", defaultValue:"TidyVNC Help"),id:"help") {
      ApplicationHelpView()
    }.defaultSize(width:720,height:640)
  }
}

@MainActor final class AppCoordinator: NSObject, NSApplicationDelegate, ObservableObject {
  private var runtime: NativeRuntime?
  private let clipboard = NativeClipboardCoordinator()
  private let bell: any NativeBellSounding = NativeSystemBell()
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
  private struct Entry { weak var window: NSWindow?; let model: ConnectionModel; var failureObservation: AnyCancellable? }
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
  private var startupListenerFailureObservation: AnyCancellable?
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
      let domain = (Bundle.main.bundleIdentifier ?? "io.github.jkeli.tidyvnc") + ".native.preferences"
      let store = NativePreferencesStore(backing: try UserDefaultsPreferencesBacking(domain:domain))
      preferences = store; settings = NativePreferencesDraft(store: store)
      importAvailability = DefaultsImportAvailability(store:store)
      if let paths = importPaths {
        defaultsImportService = NativeDefaultsImportService(paths:paths,store:store)
      }
      profileLibrary = NativeProfileLibrary(store: profiles, preferences: store)
    } catch { startupError = NativePresentationIssue(error:error,context:.startup).message }
  }
  func takeInvocation() -> NativeInvocationLaunch? { invocationStartup.take() }
  func makeConnection(profileID: UUID? = nil, document: NativeDocumentOpenRequest? = nil, launch: NativeInvocationLaunch? = nil) -> ConnectionModel {
    guard let runtime, let preferences, !quitting else { return ConnectionModel(error: startupError ?? String(localized:"app.the.application.is.closing", defaultValue:"The application is closing."),alertOnFatalError:launch?.invocation.alertOnFatalError ?? true) }
    return ConnectionModel(runtime: runtime, preferences: preferences, displays: displays, history: history, profileStore: profiles, profileID: profileID,
      document:document ?? launch?.document,invocation:launch?.invocation,connectOnReady:launch?.connectsOnReady == true,launchCredentials:launch?.credentials,credentialStore: credentials, trustStore: trustStore, savedTrustStore: savedTrust,hostKeyStore: savedHostKeys) { [weak self] session, model in
      model.fullscreen.onActivate = { [weak self, weak model] in if let model { self?.active = model } }
      self?.clipboard.register(session) { [weak model] status in model?.clipboardMessage = status }
      session.bellHandler = { [weak self] in self?.bell.ring() }
      model.copyText = { [weak self] text in try await self?.clipboard.copyLocal(text) }
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
    startupListenerFailureObservation = model.$closesAfterFailure.filter { $0 }.prefix(1).sink { [weak self, weak window, weak model] _ in
      Task { @MainActor in
        guard let self, let window, let model else { return }
        await model.close()
        guard self.startupListener === model else { return }
        window.close()
      }
    }
    window.setContentSize(NSSize(width:700,height:560))
    NotificationCenter.default.addObserver(self,selector:#selector(startupListenerClosed(_:)),name:NSWindow.willCloseNotification,object:window)
    NotificationCenter.default.addObserver(self,selector:#selector(windowActivated(_:)),name:NSWindow.didBecomeKeyNotification,object:window)
    if window.isKeyWindow { active = nil }
  }
  @objc private func startupListenerClosed(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, startupListenerWindow === window, let model = startupListener else { return }
    NotificationCenter.default.removeObserver(self,name:NSWindow.willCloseNotification,object:window)
    NotificationCenter.default.removeObserver(self,name:NSWindow.didBecomeKeyNotification,object:window)
    startupListenerFailureObservation = nil
    startupListenerWindow = nil; startupListener = nil; model.requestClose()
    startupListenerCleanup = Task { await model.close() }
  }
  private func openIncoming(_ request: ReverseConnectionRequest) -> Bool {
    guard !quitting, let runtime, let preferences else { return false }
    let model = ConnectionModel(runtime:runtime,preferences:preferences,displays:displays,reverse:request) { [weak self] session, model in
      model.fullscreen.onActivate = { [weak self, weak model] in if let model { self?.active = model } }
      self?.clipboard.register(session) { [weak model] status in model?.clipboardMessage = status }
      session.bellHandler = { [weak self] in self?.bell.ring() }
      model.copyText = { [weak self] text in try await self?.clipboard.copyLocal(text) }
    }
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:700),
      styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    window.title = String(localized:"app.incoming.connection", defaultValue:"Incoming Connection"); window.isReleasedWhenClosed = false
    let content = NSHostingController(rootView:ConnectionRoot(coordinator:self,model:model)); content.sizingOptions = [.minSize]
    window.contentViewController = content
    window.setContentSize(NSSize(width:960,height:700))
    let controller = NSWindowController(window:window); reverseWindows[ObjectIdentifier(window)] = controller
    register(window,model:model); window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
    return true
  }
  func showDefaultsImport(_ openConnection: @escaping @MainActor () -> Void) {
    guard !quitting else { return }
    if let defaultsImportWindow { defaultsImportWindow.showWindow(nil); return }
    guard let defaultsImportService else {
      let alert = NSAlert()
      alert.messageText = String(localized:"app.defaults.import.is.unavailable", defaultValue:"Defaults import is unavailable")
      alert.informativeText = String(localized:"app.check.the.native.settings.store.and.the.home.xdg.configuration.paths.then", defaultValue:"Check the native settings store and the home/XDG configuration paths, then reopen the app.")
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
      alert.messageText = String(localized:"app.history.import.is.unavailable", defaultValue:"History import is unavailable")
      alert.informativeText = String(localized:"app.check.the.home.xdg.paths.then.reopen.the.app", defaultValue:"Check the home/XDG paths, then reopen the app.")
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
    panel.title = String(localized:"app.open.connection.file", defaultValue:"Open Connection File"); panel.prompt = String(localized:"app.review", defaultValue:"Review")
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
    panel.title = String(localized:"app.save.connection.file", defaultValue:"Save Connection File"); panel.prompt = String(localized:"profiles.save", defaultValue:"Save")
    panel.allowedContentTypes = [type]; panel.allowsOtherFileTypes = false
    panel.isExtensionHidden = false; panel.canCreateDirectories = true
    panel.nameFieldStringValue = String(localized:"settings.section.connection", defaultValue:"Connection")
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
    windows[id]?.failureObservation = model.$closesAfterFailure.filter { $0 }.prefix(1).sink { [weak self, weak window, weak model] _ in
      Task { @MainActor in
        guard let self, let window, let model else { return }
        await model.close()
        guard self.windows[id]?.model === model else { return }
        window.close()
      }
    }
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
      ListenerView(model:model).navigationTitle(String(localized:"listener.listen.for.connections", defaultValue:"Listen for Connections"))
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
    CommandGroup(replacing:.help) {
      Button(String(localized:"help.title", defaultValue:"TidyVNC Help")) { openWindow(id:"help") }
        .keyboardShortcut("?",modifiers:.command)
    }
    // A SwiftUI authentication sheet can defer the standard termination action.
    // Cancel and dismiss our requests before asking AppKit to terminate.
    CommandGroup(replacing: .appTermination) {
      Button(String(localized:"app.quit.tidyvnc", defaultValue:"Quit TidyVNC")) { coordinator.requestQuit() }.keyboardShortcut("q")
    }
    CommandGroup(replacing: .newItem) {
      Button(String(localized:"import.defaults.new.connection", defaultValue:"New Connection")) { openWindow(id: "connection") }.keyboardShortcut("n")
      Button(String(localized:"app.listen.for.connections", defaultValue:"Listen for Connections…")) { coordinator.showListener() }.keyboardShortcut("l",modifiers:[.command,.shift])
      Button(String(localized:"app.open.connection.file.title", defaultValue:"Open Connection File…")) {
        coordinator.openDocument { openWindow(id:"document-connection",value:$0) }
      }.keyboardShortcut("o")
      Button(String(localized:"app.save.connection.file.as", defaultValue:"Save Connection File As…")) { coordinator.active?.beginDocumentExport() }
        .keyboardShortcut("s",modifiers:[.command,.shift])
        .disabled(coordinator.active?.canExportDocument != true)
      Divider()
      Button(String(localized:"app.import.connection.defaults", defaultValue:"Import Connection Defaults…")) { coordinator.showDefaultsImport { openWindow(id:"connection") } }
      Button(String(localized:"app.import.recent.connections", defaultValue:"Import Recent Connections…")) { coordinator.showHistoryImport() }
      Divider()
      Button(String(localized:"app.saved.server.keys", defaultValue:"Saved Server Keys…")) { openWindow(id: "server-keys") }
      Button(String(localized:"app.saved.certificate.decisions", defaultValue:"Saved Certificate Decisions…")) { openWindow(id: "trust-decisions") }
      Button(String(localized:"app.saved.profiles", defaultValue:"Saved Profiles…")) { openWindow(id: "profiles") }.keyboardShortcut("p", modifiers: [.command, .shift])
    }
    CommandMenu(String(localized:"settings.section.connection", defaultValue:"Connection")) {
      if let model = coordinator.active { DesktopActions(model: model) }
      else { Text(String(localized:"app.no.active.connection", defaultValue:"No active connection")) }
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
            Button(String(localized:"app.retry.command.line.options", defaultValue:"Retry Command-Line Options")) { defaults.load() }
              .accessibilityIdentifier("invocation.retry")
          } else if let issue = defaults.documentIssue {
            Text(issue).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("document.error")
            Button(String(localized:"listener.reload.connection.file", defaultValue:"Reload Connection File")) { defaults.load() }
          } else if let error = defaults.profileError {
            Text(profileMessage(error)).fixedSize(horizontal: false, vertical: true)
            Button(String(localized:"app.retry.profile", defaultValue:"Retry Profile")) { defaults.load() }
          } else if let error = defaults.error {
            Text(preferencesMessage(error)).fixedSize(horizontal: false, vertical: true)
            Button(String(localized:"listener.retry.defaults", defaultValue:"Retry Defaults")) { defaults.load() }
            Button(String(localized:"app.use.built.in.defaults.for.this.connection", defaultValue:"Use Built-in Defaults for This Connection")) { defaults.useBuiltInDefaults() }
          } else { ProgressView(String(localized:"app.loading.connection.defaults", defaultValue:"Loading connection defaults…")) }
        }.padding(24)
      }
      else { ContentUnavailableView(String(localized:"app.unable.to.start.a.connection", defaultValue:"Unable to start a connection"), systemImage: "exclamationmark.triangle", description: Text(model.message ?? String(localized:"app.please.try.again", defaultValue:"Please try again."))) }
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
    .navigationTitle(model.isReverse ? String(localized:"app.incoming.connection", defaultValue:"Incoming Connection") : model.defaults?.documentRequest?.url.lastPathComponent ?? "TidyVNC")
    .onAppear {
      guard !model.isReverse else { return }
      // Capture only the scene action, not this root or its connection model.
      let action = openWindow
      coordinator.installDocumentRouting { action(id:"document-connection",value:$0) }
    }
    .background(WindowRegistration(coordinator: coordinator, model: model).frame(width: 0, height: 0))
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
