// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine
import NativeTestSupport
import TidyVNCNative

@MainActor private final class DisplayRows: NSStackView { override var isFlipped: Bool { true } }
@MainActor private final class ComparisonContent: NSView {
  override var isOpaque: Bool { true }
  override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

// Developer-only visible comparison app. It never loads user preferences,
// credentials, trust files or remote endpoints. --verify constructs it offscreen.
@MainActor final class Comparison: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
  let runtime: NativeRuntime
  let session: NativeSession
  let displays = NativeDisplayService()
  let scaling = NativeScalingState(), input = NativeInputState(), commands = NativeDesktopCommands()
  let desktop = NativeDesktopView(frame:.init(x:0,y:0,width:640,height:400))
  let window = NSWindow(contentRect:.init(x:100,y:100,width:920,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  private var owner: NativeFullscreenController!
  private var peer: UnsafeMutableRawPointer?
  private var operation: Task<Void,Never>?
  private var ownerObservation: AnyCancellable?
  private var subscriptions = Set<AnyCancellable>()
  private var busy = true, quitting = false
  private let verify: Bool
  private let outputDirectory: String?
  private var selected = Set<NativeDisplayID>()
  private var preferredStrategy = NativeFullscreenStrategy.nativeSpace
  private let mode = NSPopUpButton(), scale = NSPopUpButton()
  private let device = NSButton(checkboxWithTitle:"Device-pixel units",target:nil,action:nil)
  private let native = NSButton(title:"Native Space",target:nil,action:nil)
  private let borderless = NSButton(title:"Borderless",target:nil,action:nil)
  private let exitButton = NSButton(title:"Exit Full Screen",target:nil,action:nil)
  private let restart = NSButton(title:"Restart Test Desktop",target:nil,action:nil)
  private let displayRows = DisplayRows()
  private let displayScroll = NSScrollView()
  private var displayHeight: NSLayoutConstraint?
  private let status = NSTextField(wrappingLabelWithString:"Starting the local test desktop…")
  private let detail = NSTextField(wrappingLabelWithString:"")
  private var localMessage: String?
  private var eventLog: [String] = []
  private let liveLog = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("tidyvnc-fullscreen-comparison-events.txt")

  init(verify: Bool, outputDirectory: String?) throws {
    self.verify = verify; self.outputDirectory = outputDirectory
    runtime = try NativeRuntime()
    var configuration = NativeSessionConfiguration()
    configuration.clipboardSend = false; configuration.clipboardReceive = false
    configuration.securityTypes = [1] // The in-process loopback fixture advertises only None.
    configuration.input = NativeInputSettings(fullscreenSystemKeys:false)
    configuration.scaling = try NativeScaling("Auto",filter:.nearest)
    configuration.resizePolicy = try .init(enabled:false)
    session = try runtime.makeSession(configuration:configuration)
    super.init()
    scaling.bind(session); input.bind(session); commands.bind(session)
    desktop.bind(session); desktop.observeScaling(scaling); desktop.observeInput(input); desktop.observeCommands(commands)
    desktop.onError = { [weak self] message in self?.localMessage = message; self?.updateStatus() }
    desktop.onContextMenu = { [weak self] view in self?.showContextMenu(view) }
    commands.onEnterFullscreen = { [weak self] in
      guard let self else { throw NativeDesktopCommandIssue.unavailable }
      try self.enter(self.preferredStrategy)
    }
    window.isReleasedWhenClosed = false; window.title = "TidyVNC Fullscreen Comparison"
    window.collectionBehavior = [.fullScreenNone]
    window.minSize = .init(width:760,height:560); window.delegate = self
    buildContent(); buildMenu(); makeOwner()
    selected = Set(displays.snapshot.displays.map(\.id)); rebuildDisplays()
    displays.$snapshot.dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.rebuildDisplays(); self?.updateStatus() }
    }.store(in:&subscriptions)
    session.$snapshot.sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.updateStatus() }
    }.store(in:&subscriptions)
    commands.objectWillChange.sink { [weak self] in
      Task { @MainActor [weak self] in self?.updateStatus() }
    }.store(in:&subscriptions)
    for name in [NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification] {
      NotificationCenter.default.publisher(for:name).sink { [weak self] notice in MainActor.assumeIsolated {
        guard let self, let window = notice.object as? NSWindow, window === self.window else { return }
        self.record("\(notice.name.rawValue) · original minimized=\(window.isMiniaturized)")
        self.updateStatus()
      } }.store(in:&subscriptions)
    }
  }
  private func makeOwner() {
    owner = NativeFullscreenController(session:session,source:desktop,displays:displays,scaling:scaling,input:input,commands:commands)
    ownerObservation = owner.objectWillChange.sink { [weak self] in
      Task { @MainActor [weak self] in self?.updateStatus() }
    }
  }
  private func row(_ views: [NSView]) -> NSStackView {
    let result = NSStackView(views:views); result.orientation = .horizontal; result.spacing = 10; result.alignment = .centerY
    return result
  }
  private func buildContent() {
    mode.addItems(withTitles:["Current display","All displays","Selected displays"])
    mode.target = self; mode.action = #selector(controlsChanged)
    scale.addItems(withTitles:["Stretch to canvas","Keep aspect ratio","Large desktop (4000 × 2000)"])
    scale.target = self; scale.action = #selector(scalingChanged)
    device.target = self; device.action = #selector(scalingChanged)
    for (button,action) in [(native,#selector(enterNative)),(borderless,#selector(enterBorderless)),(exitButton,#selector(exitFullscreen)),(restart,#selector(restartDesktop))] {
      button.target = self; button.action = action; button.bezelStyle = .rounded
    }
    native.setAccessibilityIdentifier("comparison.native"); borderless.setAccessibilityIdentifier("comparison.borderless")
    exitButton.setAccessibilityIdentifier("comparison.exit"); restart.setAccessibilityIdentifier("comparison.restart")
    mode.setAccessibilityIdentifier("comparison.selection"); scale.setAccessibilityIdentifier("comparison.scaling")
    device.setAccessibilityIdentifier("comparison.devicePixels")
    let heading = NSTextField(labelWithString:"Fullscreen comparison")
    heading.font = .systemFont(ofSize:22,weight:.semibold)
    let explanation = NSTextField(wrappingLabelWithString:"Compare native Spaces and borderless windows using the built-in local test desktop. No saved connections or settings are used.")
    let instructions = NSTextField(wrappingLabelWithString:"Exit from any surface with Control–Option–Return, or choose Desktop → Exit Full Screen. Control–Option–M opens desktop actions. Automatic keyboard capture and clipboard sharing are off.")
    instructions.textColor = .secondaryLabelColor
    displayRows.orientation = .vertical; displayRows.alignment = .leading; displayRows.spacing = 4
    displayRows.autoresizingMask = [.width]
    displayScroll.documentView = displayRows; displayScroll.hasVerticalScroller = true
    displayScroll.autohidesScrollers = true; displayScroll.drawsBackground = false
    displayHeight = displayScroll.heightAnchor.constraint(equalToConstant:24)
    displayHeight?.isActive = true
    status.setAccessibilityIdentifier("comparison.status"); detail.textColor = .secondaryLabelColor
    desktop.translatesAutoresizingMaskIntoConstraints = false
    let controls = NSStackView(views:[heading,explanation,row([mode,native,borderless,exitButton]),displayScroll,
      row([scale,device,restart]),instructions,status,detail])
    controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 10
    let content = ComparisonContent(); window.contentView = content
    content.addSubview(controls); content.addSubview(desktop)
    controls.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      controls.topAnchor.constraint(equalTo:content.topAnchor,constant:18),
      controls.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:18),
      controls.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-18),
      displayScroll.widthAnchor.constraint(equalTo:controls.widthAnchor),
      explanation.widthAnchor.constraint(equalTo:controls.widthAnchor),instructions.widthAnchor.constraint(equalTo:controls.widthAnchor),
      status.widthAnchor.constraint(equalTo:controls.widthAnchor),detail.widthAnchor.constraint(equalTo:controls.widthAnchor),
      desktop.topAnchor.constraint(equalTo:controls.bottomAnchor,constant:14),
      desktop.leadingAnchor.constraint(equalTo:content.leadingAnchor),desktop.trailingAnchor.constraint(equalTo:content.trailingAnchor),
      desktop.bottomAnchor.constraint(equalTo:content.bottomAnchor),desktop.heightAnchor.constraint(greaterThanOrEqualToConstant:200)
    ])
  }
  private func buildMenu() {
    let bar = NSMenu(), application = NSMenu(title:"Comparison"), actions = NSMenu(title:"Desktop")
    let appItem = NSMenuItem(); appItem.submenu = application; bar.addItem(appItem)
    let quit = NSMenuItem(title:"Quit Fullscreen Comparison",action:#selector(quitApplication),keyEquivalent:"q")
    quit.target = self; application.addItem(quit)
    let desktopItem = NSMenuItem(title:"Desktop",action:nil,keyEquivalent:""); desktopItem.submenu = actions; bar.addItem(desktopItem)
    let exit = NSMenuItem(title:"Exit Full Screen",action:#selector(exitFullscreen),keyEquivalent:"f")
    exit.keyEquivalentModifierMask = [.control,.command]; exit.target = self; actions.addItem(exit)
    let minimize = NSMenuItem(title:"Minimize",action:#selector(minimizeDesktop),keyEquivalent:"m")
    minimize.target = self; actions.addItem(minimize)
    let restore = NSMenuItem(title:"Restore Test Desktop",action:#selector(restoreDesktop),keyEquivalent:"")
    restore.target = self; actions.addItem(restore)
    actions.addItem(.separator())
    for (index,direction) in NativeDesktopPan.allCases.enumerated() {
      let item = NSMenuItem(title:direction.title,action:#selector(pan(_:)),keyEquivalent:"")
      item.tag = index; item.target = self; actions.addItem(item)
    }
    actions.addItem(.separator())
    for (title,action) in [("Capture Keyboard",#selector(captureKeyboard)),("Release Keyboard",#selector(releaseKeyboard))] {
      let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; actions.addItem(item)
    }
    NSApp.mainMenu = bar
  }
  private func rebuildDisplays() {
    for view in displayRows.arrangedSubviews { displayRows.removeArrangedSubview(view); view.removeFromSuperview() }
    for display in displays.snapshot.displays {
      let button = NSButton(checkboxWithTitle:"\(display.name) — \(Int(display.bounds.width)) × \(Int(display.bounds.height)), \(display.backingScale)×",target:self,action:#selector(selectDisplay(_:)))
      button.identifier = .init(display.id.rawValue); button.state = selected.contains(display.id) ? .on : .off
      displayRows.addArrangedSubview(button)
    }
    let height = CGFloat(max(1,displays.snapshot.displays.count))*24
    displayHeight?.constant = min(96,height)
    displayRows.setFrameSize(.init(width:max(1,displayScroll.contentSize.width),height:height))
    updateStatus()
  }
  @objc private func selectDisplay(_ sender: NSButton) {
    guard let value = sender.identifier?.rawValue else { return }
    if sender.state == .on { selected.insert(.init(value)) } else { selected.remove(.init(value)) }
    updateStatus()
  }
  @objc private func controlsChanged() { updateStatus() }
  @objc private func scalingChanged() {
    let draft = NativeScalingDraft(state:scaling)
    switch scale.indexOfSelectedItem {
    case 1: draft.mode = .fixedRatio
    case 2: draft.mode = .exact; draft.text = "4000x2000"
    default: draft.mode = .automatic
    }
    draft.devicePixels = device.state == .on
    if !draft.apply() { localMessage = "Scaling could not be applied: \(String(describing:draft.issue))" }
    updateStatus()
  }
  private func enter(_ strategy: NativeFullscreenStrategy) throws {
    guard !busy, !quitting, session.snapshot.state == .connected, owner.phase == .windowed else { throw NativeDesktopCommandIssue.unavailable }
    let selection: NativeFullscreenSelection
    switch mode.indexOfSelectedItem {
    case 1: selection = .all
    case 2: selection = .selected(selected.sorted { $0.rawValue < $1.rawValue })
    default: selection = .current
    }
    localMessage = nil; preferredStrategy = strategy
    try owner.enter(selection,strategy:strategy)
    updateStatus()
  }
  private func attempt(_ work: () throws -> Void) {
    do { try work() } catch { localMessage = String(describing:error) }
    updateStatus()
  }
  @objc private func enterNative() { attempt { try enter(.nativeSpace) } }
  @objc private func enterBorderless() { attempt { try enter(.borderless) } }
  @objc private func exitFullscreen() { if owner.phase != .windowed { attempt { try commands.perform(.fullscreen) } } }
  @objc private func minimizeDesktop() { attempt { try commands.perform(.minimize) } }
  @objc private func restoreDesktop() {
    guard owner.phase == .windowed, !commands.isMinimizing else { return }
    window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
  }
  @objc private func pan(_ sender: NSMenuItem) {
    guard NativeDesktopPan.allCases.indices.contains(sender.tag) else { return }
    attempt { try commands.perform(.pan(NativeDesktopPan.allCases[sender.tag])) }
  }
  @objc private func captureKeyboard() { attempt { try commands.perform(.captureKeyboard) } }
  @objc private func releaseKeyboard() { attempt { try commands.perform(.releaseKeyboard) } }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(exitFullscreen) { return owner.phase != .windowed && commands.canPerform(.fullscreen) }
    if item.action == #selector(minimizeDesktop) { return commands.canPerform(.minimize) }
    if item.action == #selector(restoreDesktop) { return owner.phase == .windowed && !commands.isMinimizing && window.isMiniaturized }
    if item.action == #selector(pan(_:)), NativeDesktopPan.allCases.indices.contains(item.tag) { return commands.canPerform(.pan(NativeDesktopPan.allCases[item.tag])) }
    if item.action == #selector(captureKeyboard) { return commands.canPerform(.captureKeyboard) }
    if item.action == #selector(releaseKeyboard) { return commands.canPerform(.releaseKeyboard) }
    return !quitting
  }
  private func showContextMenu(_ view: NSView) {
    guard let menu = NSApp.mainMenu?.items.last?.submenu?.copy() as? NSMenu else { return }
    menu.popUp(positioning:nil,at:view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero,from:nil),in:view)
  }
  private func updateStatus() {
    guard owner != nil else { return }
    let ready = !busy && !quitting && !commands.isMinimizing && session.snapshot.state == .connected
    let windowed = owner.phase == .windowed
    mode.isEnabled = ready && windowed; native.isEnabled = ready && windowed
    borderless.isEnabled = ready && windowed; restart.isEnabled = !busy && windowed && !quitting
    exitButton.isEnabled = !windowed && commands.canPerform(.fullscreen)
    scale.isEnabled = ready && windowed; device.isEnabled = ready && windowed
    for case let button as NSButton in displayRows.arrangedSubviews { button.isEnabled = ready && windowed && mode.indexOfSelectedItem == 2 }
    let phase: String
    switch owner.phase { case .windowed: phase = "Windowed"; case .entering: phase = "Entering full screen"; case .active: phase = "Full screen"; case .exiting: phase = "Exiting full screen" }
    status.stringValue = busy ? "Connecting to the local test desktop…" : "\(phase) · \(displays.snapshot.displays.count) display(s) · \(session.snapshot.state)"
    let missing = selected.subtracting(Set(displays.snapshot.displays.map(\.id))).count
    detail.stringValue = localMessage ?? owner.message ?? commands.windowMessage ?? commands.captureMessage ?? (missing > 0 ? "\(missing) selected display(s) are unavailable." : "Red/green above blue/white form one shared desktop across the selected displays.")
    record("\(status.stringValue) | \(detail.stringValue)")
  }
  private func record(_ line: String) {
    if eventLog.last != line {
      eventLog.append(line); print(line)
      if !verify {
        // This developer fixture logs only local test state, never user connections.
        try? eventLog.joined(separator:"\n").write(to:liveLog,atomically:true,encoding:.utf8)
      }
    }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    if !verify { window.makeKeyAndOrderFront(nil); NSApp.activate() }
    restartDesktop()
  }
  @objc private func restartDesktop() {
    guard !quitting, operation == nil else { return }
    busy = true; localMessage = nil; owner.stop(); updateStatus()
    operation = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if ![.idle,.closed,.failed].contains(session.snapshot.state) { _ = try await session.disconnect() }
        if let peer { native_test_peer_destroy(peer); self.peer = nil }
        guard let next = native_test_peer_create_pattern(0) else { throw NativeDisplayError.unavailable }
        peer = next; makeOwner()
        _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(next))")
        busy = false; operation = nil; updateStatus()
        if verify { try await verifyConstruction(); await shutdown(); exit(0) }
      } catch {
        busy = false; operation = nil; localMessage = String(describing:error); updateStatus()
        if verify { print("FAIL \(error)"); await shutdown(); exit(1) }
      }
    }
  }
  private func verifyConstruction() async throws {
    window.contentView?.layoutSubtreeIfNeeded()
    for _ in 0..<2500 {
      if (try? session.frame?.copyPixels().prefix(4)) == Data([0,0,255,0]), desktop.displayedSequence == session.frame?.sequence, !desktop.isRendering { break }
      try await Task.sleep(for:.milliseconds(2))
    }
    guard !window.isVisible, (try? session.frame?.copyPixels().prefix(4)) == Data([0,0,255,0]),
          desktop.displayedSequence == session.frame?.sequence, !desktop.isRendering,
          desktop.displayedImage != nil, native.isEnabled, borderless.isEnabled,
          !exitButton.isEnabled, mode.numberOfItems == 3, !displays.snapshot.displays.isEmpty,
          session.clipboardSendEnabled == false, session.clipboardReceiveEnabled == false,
          input.value.fullscreenSystemKeys == false else { throw NativeDisplayError.invalidSnapshot }
    if let outputDirectory, let content = window.contentView {
      let directory = URL(fileURLWithPath:outputDirectory,isDirectory:true)
      try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
      for dark in [false,true] {
        window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
        try await Task.sleep(for:.milliseconds(50))
        content.layoutSubtreeIfNeeded(); content.needsDisplay = true; content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) else { throw NativeDisplayError.unavailable }
        content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in:content.bounds,to:bitmap) }
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw NativeDisplayError.unavailable }
        try data.write(to:directory.appendingPathComponent(dark ? "fullscreen-comparison-dark.png" : "fullscreen-comparison.png"))
      }
      try eventLog.joined(separator:"\n").write(to:directory.appendingPathComponent("events.txt"),atomically:true,encoding:.utf8)
    }
    print("PASS hidden comparison harness construction, local pattern, controls and isolated configuration; no fullscreen transition requested")
  }
  @objc private func quitApplication() { NSApp.terminate(nil) }
  func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !quitting else { return .terminateLater }
    quitting = true; operation?.cancel()
    Task { @MainActor in
      await operation?.value; await shutdown(); sender.reply(toApplicationShouldTerminate:true)
    }
    return .terminateLater
  }
  private func shutdown() async {
    quitting = true; owner.stop(); ownerObservation = nil; subscriptions.removeAll()
    desktop.detach(); commands.stop(); input.stop(); scaling.stop(); displays.stop()
    try? await session.close(); try? await runtime.shutdown()
    if let peer { native_test_peer_destroy(peer); self.peer = nil }
    window.delegate = nil; window.contentView = nil; window.close()
  }
}
@main struct Main {
  static func main() {
    let verify = CommandLine.arguments.contains("--verify")
    let output = CommandLine.arguments.firstIndex(of:"--output").flatMap { index in CommandLine.arguments.indices.contains(index+1) ? CommandLine.arguments[index+1] : nil }
    let app = NSApplication.shared
    app.setActivationPolicy(verify ? .prohibited : .regular)
    do {
      let comparison = try Comparison(verify:verify,outputDirectory:output)
      app.delegate = comparison
      withExtendedLifetime(comparison) { app.run() }
    } catch { print("FAIL \(error)"); exit(1) }
  }
}
