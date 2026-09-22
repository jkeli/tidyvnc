// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import TidyVNCNative

struct DesktopActions: View {
  @ObservedObject var model: ConnectionModel
  var body: some View {
    Button("Disconnect") { model.disconnect() }.disabled(model.closing || model.busy || model.session?.snapshot.state != .connected)
    Divider()
    action(model.desktopCommands.isFullscreen ? "Exit Full Screen" : "Enter Full Screen", .fullscreen, "desktop.fullscreen").keyboardShortcut("f",modifiers:[.control,.command])
    action("Minimize", .minimize, "desktop.minimize").keyboardShortcut("m")
    action("Resize Window to Desktop", .fitWindow, "desktop.fitWindow")
    Button("Resize Remote Desktop…") { model.openRemoteResize() }.disabled(!model.canOpenRemoteResize)
      .help("Requires server resize support and input access.")
    Menu("Pan Desktop") {
      ForEach(NativeDesktopPan.allCases, id: \.self) { direction in
        action(direction.title, .pan(direction), "desktop.pan.\(direction)")
      }
    }.accessibilityIdentifier("desktop.pan")
    Divider()
    Toggle("Hold Control", isOn: Binding(get: { model.desktopCommands.controlSelected }, set: { _ in model.performDesktop(.control) }))
      .disabled(!can(.control)).accessibilityIdentifier("desktop.control")
    Toggle("Hold Alt", isOn: Binding(get: { model.desktopCommands.altSelected }, set: { _ in model.performDesktop(.alt) }))
      .disabled(!can(.alt)).accessibilityIdentifier("desktop.alt")
    action(model.desktopCommands.keyboardCaptured ? "Release Keyboard" : "Capture Keyboard",
      model.desktopCommands.keyboardCaptured ? .releaseKeyboard : .captureKeyboard, "desktop.captureKeyboard")
    action("Send Ctrl-Alt-Delete", .controlAltDelete, "desktop.controlAltDelete")
    Divider()
    Button("Refresh Desktop") { model.refresh() }.disabled(model.closing || model.session?.snapshot.state != .connected)
    Menu("Connection Settings") {
      Button("Fullscreen Displays…") { model.openFullscreen() }.disabled(!model.canOpenFullscreen)
      Button("Input…") { model.openInput() }.disabled(!model.canOpenInput)
      Button("Remote Resize…") { model.openResizePolicy() }.disabled(!model.canOpenResizePolicy)
      Button("Scaling…") { model.openScaling() }.disabled(!model.canOpenScaling)
      Button("Connection…") { model.openConnectionOptions() }.disabled(!model.canOpenConnectionOptions)
        .help("Disconnect before changing shared access or Retry options.")
      Button("Security…") { model.openSecurity() }.disabled(!model.canOpenSecurity)
        .help("Disconnect before editing security for the next connection.")
      Button("Encoding…") { model.openEncoding() }.disabled(!model.canOpenEncoding)
    }
    Button("Connection Information…") { model.openInformation() }.disabled(!model.canOpenInformation)
      .accessibilityIdentifier("desktop.information")
    Toggle("Show Connection Statistics", isOn: Binding(get: { model.showsStatistics }, set: { _ in model.toggleStatistics() }))
      .disabled(!model.canToggleStatistics).accessibilityIdentifier("desktop.statistics")
    Divider()
    Button(String(localized:"about.action", defaultValue:"About TidyVNC…")) { NSApp.orderFrontStandardAboutPanel(nil) }
  }
  private func can(_ command: NativeDesktopCommand) -> Bool { !model.closing && !model.busy && model.desktopCommands.canPerform(command) }
  private func action(_ title: String, _ command: NativeDesktopCommand, _ identifier: String) -> some View {
    Button(title) { model.performDesktop(command) }.disabled(!can(command)).accessibilityIdentifier(identifier)
  }
}

// Kept alive by the synchronous popup call; actions recheck the connection model.
@MainActor final class DesktopContextMenu: NSObject {
  private weak var model: ConnectionModel?
  private var actions: [() -> Void] = []
  init(model: ConnectionModel) { self.model = model }
  func makeMenu() -> NSMenu {
    let menu = NSMenu(title: "Connection"); menu.autoenablesItems = false
    guard let model else { return menu }
    func item(_ title: String, enabled: Bool = true, selected: Bool = false, action: @escaping () -> Void) {
      let entry = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
      entry.target = self; entry.tag = actions.count; entry.isEnabled = enabled; entry.state = selected ? .on : .off
      actions.append(action); menu.addItem(entry)
    }
    func command(_ title: String, _ value: NativeDesktopCommand, selected: Bool = false) {
      item(title, enabled: !model.closing && !model.busy && model.desktopCommands.canPerform(value), selected: selected) { [weak model] in model?.performDesktop(value) }
    }
    actions.removeAll()
    item("Disconnect", enabled: !model.closing && !model.busy && model.session?.snapshot.state == .connected) { [weak model] in model?.disconnect() }
    menu.addItem(.separator())
    command(model.desktopCommands.isFullscreen ? "Exit Full Screen" : "Enter Full Screen", .fullscreen)
    command("Minimize", .minimize); command("Resize Window to Desktop", .fitWindow)
    item("Resize Remote Desktop…", enabled:model.canOpenRemoteResize) { [weak model] in model?.openRemoteResize() }
    let panMenu = NSMenu(title: "Pan Desktop"); panMenu.autoenablesItems = false
    let panItem = NSMenuItem(title: "Pan Desktop", action: nil, keyEquivalent: "")
    panItem.submenu = panMenu; menu.addItem(panItem)
    for direction in NativeDesktopPan.allCases {
      command(direction.title, .pan(direction))
      let entry = menu.items.last!; menu.removeItem(entry); panMenu.addItem(entry)
    }
    menu.addItem(.separator())
    command("Hold Control", .control, selected: model.desktopCommands.controlSelected)
    command("Hold Alt", .alt, selected: model.desktopCommands.altSelected)
    command(model.desktopCommands.keyboardCaptured ? "Release Keyboard" : "Capture Keyboard", model.desktopCommands.keyboardCaptured ? .releaseKeyboard : .captureKeyboard)
    command("Send Ctrl-Alt-Delete", .controlAltDelete)
    menu.addItem(.separator())
    item("Refresh Desktop", enabled: !model.closing && model.session?.snapshot.state == .connected) { [weak model] in model?.refresh() }
    item("Fullscreen Displays…", enabled:model.canOpenFullscreen) { [weak model] in model?.openFullscreen() }
    item("Input Settings…", enabled: model.canOpenInput) { [weak model] in model?.openInput() }
    item("Remote Resize Settings…", enabled:model.canOpenResizePolicy) { [weak model] in model?.openResizePolicy() }
    item("Scaling Settings…", enabled: model.canOpenScaling) { [weak model] in model?.openScaling() }
    item("Connection Options…", enabled: model.canOpenConnectionOptions) { [weak model] in model?.openConnectionOptions() }
    item("Security Settings…", enabled: model.canOpenSecurity) { [weak model] in model?.openSecurity() }
    item("Encoding Settings…", enabled: model.canOpenEncoding) { [weak model] in model?.openEncoding() }
    item("Connection Information…", enabled: model.canOpenInformation) { [weak model] in model?.openInformation() }
    item("Show Connection Statistics", enabled: model.canToggleStatistics, selected: model.showsStatistics) { [weak model] in model?.toggleStatistics() }
    menu.addItem(.separator())
    item(String(localized:"about.action", defaultValue:"About TidyVNC…")) { NSApp.orderFrontStandardAboutPanel(nil) }
    return menu
  }
  @objc private func invoke(_ item: NSMenuItem) {
    guard actions.indices.contains(item.tag), item.isEnabled else { return }
    actions[item.tag]()
  }
  func show(in view: NSView) {
    let menu = makeMenu()
    let point = view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
    withExtendedLifetime(self) {
      _ = menu.popUp(positioning: nil, at: view.bounds.contains(point) ? point : CGPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }
  }
}
