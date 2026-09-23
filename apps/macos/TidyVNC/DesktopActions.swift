// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import TidyVNCNative

struct DesktopActions: View {
  @ObservedObject var model: ConnectionModel
  var body: some View {
    Button(String(localized:"app.disconnect", defaultValue:"Disconnect")) { model.disconnect() }.disabled(model.closing || model.busy || model.session?.snapshot.state != .connected)
    Divider()
    action(model.desktopCommands.isFullscreen ? String(localized:"desktop.exit.full.screen", defaultValue:"Exit Full Screen") : String(localized:"desktop.enter.full.screen", defaultValue:"Enter Full Screen"), .fullscreen, "desktop.fullscreen").keyboardShortcut("f",modifiers:[.control,.command])
    action(String(localized:"desktop.minimize", defaultValue:"Minimize"), .minimize, "desktop.minimize").keyboardShortcut("m")
    action(String(localized:"desktop.resize.window.to.desktop", defaultValue:"Resize Window to Desktop"), .fitWindow, "desktop.fitWindow")
    Button(String(localized:"desktop.resize.remote.desktop", defaultValue:"Resize Remote Desktop…")) { model.openRemoteResize() }.disabled(!model.canOpenRemoteResize)
      .help(String(localized:"desktop.requires.server.resize.support.and.input.access", defaultValue:"Requires server resize support and input access."))
    Menu(String(localized:"desktop.pan.desktop", defaultValue:"Pan Desktop")) {
      ForEach(NativeDesktopPan.allCases, id: \.self) { direction in
        action(direction.title, .pan(direction), "desktop.pan.\(direction)")
      }
    }.accessibilityIdentifier("desktop.pan")
    Divider()
    Toggle(String(localized:"desktop.hold.control", defaultValue:"Hold Control"), isOn: Binding(get: { model.desktopCommands.controlSelected }, set: { _ in model.performDesktop(.control) }))
      .disabled(!can(.control)).accessibilityIdentifier("desktop.control")
    Toggle(String(localized:"desktop.hold.alt", defaultValue:"Hold Alt"), isOn: Binding(get: { model.desktopCommands.altSelected }, set: { _ in model.performDesktop(.alt) }))
      .disabled(!can(.alt)).accessibilityIdentifier("desktop.alt")
    action(model.desktopCommands.keyboardCaptured ? String(localized:"desktop.release.keyboard", defaultValue:"Release Keyboard") : String(localized:"desktop.capture.keyboard", defaultValue:"Capture Keyboard"),
      model.desktopCommands.keyboardCaptured ? .releaseKeyboard : .captureKeyboard, "desktop.captureKeyboard")
    action(String(localized:"desktop.send.ctrl.alt.delete", defaultValue:"Send Ctrl-Alt-Delete"), .controlAltDelete, "desktop.controlAltDelete")
    Divider()
    Button(String(localized:"desktop.refresh.desktop", defaultValue:"Refresh Desktop")) { model.refresh() }.disabled(model.closing || model.session?.snapshot.state != .connected)
    Menu(String(localized:"desktop.connection.settings", defaultValue:"Connection Settings")) {
      Button(String(localized:"desktop.fullscreen.displays", defaultValue:"Fullscreen Displays…")) { model.openFullscreen() }.disabled(!model.canOpenFullscreen)
      Button(String(localized:"desktop.input", defaultValue:"Input…")) { model.openInput() }.disabled(!model.canOpenInput)
      Button(String(localized:"desktop.remote.resize", defaultValue:"Remote Resize…")) { model.openResizePolicy() }.disabled(!model.canOpenResizePolicy)
      Button(String(localized:"desktop.scaling", defaultValue:"Scaling…")) { model.openScaling() }.disabled(!model.canOpenScaling)
      Button(String(localized:"desktop.connection", defaultValue:"Connection…")) { model.openConnectionOptions() }.disabled(!model.canOpenConnectionOptions)
        .help(String(localized:"desktop.disconnect.before.changing.shared.access.or.retry.options", defaultValue:"Disconnect before changing shared access or Retry options."))
      Button(String(localized:"desktop.security", defaultValue:"Security…")) { model.openSecurity() }.disabled(!model.canOpenSecurity)
        .help(String(localized:"desktop.disconnect.before.editing.security.for.the.next.connection", defaultValue:"Disconnect before editing security for the next connection."))
      Button(String(localized:"desktop.encoding", defaultValue:"Encoding…")) { model.openEncoding() }.disabled(!model.canOpenEncoding)
    }
    Button(String(localized:"desktop.connection.information", defaultValue:"Connection Information…")) { model.openInformation() }.disabled(!model.canOpenInformation)
      .accessibilityIdentifier("desktop.information")
    Toggle(String(localized:"desktop.show.connection.statistics", defaultValue:"Show Connection Statistics"), isOn: Binding(get: { model.showsStatistics }, set: { _ in model.toggleStatistics() }))
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
    let menu = NSMenu(title: String(localized:"settings.section.connection", defaultValue:"Connection")); menu.autoenablesItems = false
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
    item(String(localized:"app.disconnect", defaultValue:"Disconnect"), enabled: !model.closing && !model.busy && model.session?.snapshot.state == .connected) { [weak model] in model?.disconnect() }
    menu.addItem(.separator())
    command(model.desktopCommands.isFullscreen ? String(localized:"desktop.exit.full.screen", defaultValue:"Exit Full Screen") : String(localized:"desktop.enter.full.screen", defaultValue:"Enter Full Screen"), .fullscreen)
    command(String(localized:"desktop.minimize", defaultValue:"Minimize"), .minimize); command(String(localized:"desktop.resize.window.to.desktop", defaultValue:"Resize Window to Desktop"), .fitWindow)
    item(String(localized:"desktop.resize.remote.desktop", defaultValue:"Resize Remote Desktop…"), enabled:model.canOpenRemoteResize) { [weak model] in model?.openRemoteResize() }
    let panMenu = NSMenu(title: String(localized:"desktop.pan.desktop", defaultValue:"Pan Desktop")); panMenu.autoenablesItems = false
    let panItem = NSMenuItem(title: String(localized:"desktop.pan.desktop", defaultValue:"Pan Desktop"), action: nil, keyEquivalent: "")
    panItem.submenu = panMenu; menu.addItem(panItem)
    for direction in NativeDesktopPan.allCases {
      command(direction.title, .pan(direction))
      let entry = menu.items.last!; menu.removeItem(entry); panMenu.addItem(entry)
    }
    menu.addItem(.separator())
    command(String(localized:"desktop.hold.control", defaultValue:"Hold Control"), .control, selected: model.desktopCommands.controlSelected)
    command(String(localized:"desktop.hold.alt", defaultValue:"Hold Alt"), .alt, selected: model.desktopCommands.altSelected)
    command(model.desktopCommands.keyboardCaptured ? String(localized:"desktop.release.keyboard", defaultValue:"Release Keyboard") : String(localized:"desktop.capture.keyboard", defaultValue:"Capture Keyboard"), model.desktopCommands.keyboardCaptured ? .releaseKeyboard : .captureKeyboard)
    command(String(localized:"desktop.send.ctrl.alt.delete", defaultValue:"Send Ctrl-Alt-Delete"), .controlAltDelete)
    menu.addItem(.separator())
    item(String(localized:"desktop.refresh.desktop", defaultValue:"Refresh Desktop"), enabled: !model.closing && model.session?.snapshot.state == .connected) { [weak model] in model?.refresh() }
    item(String(localized:"desktop.fullscreen.displays", defaultValue:"Fullscreen Displays…"), enabled:model.canOpenFullscreen) { [weak model] in model?.openFullscreen() }
    item(String(localized:"desktop.input.settings", defaultValue:"Input Settings…"), enabled: model.canOpenInput) { [weak model] in model?.openInput() }
    item(String(localized:"desktop.remote.resize.settings", defaultValue:"Remote Resize Settings…"), enabled:model.canOpenResizePolicy) { [weak model] in model?.openResizePolicy() }
    item(String(localized:"desktop.scaling.settings", defaultValue:"Scaling Settings…"), enabled: model.canOpenScaling) { [weak model] in model?.openScaling() }
    item(String(localized:"desktop.connection.options", defaultValue:"Connection Options…"), enabled: model.canOpenConnectionOptions) { [weak model] in model?.openConnectionOptions() }
    item(String(localized:"desktop.security.settings", defaultValue:"Security Settings…"), enabled: model.canOpenSecurity) { [weak model] in model?.openSecurity() }
    item(String(localized:"desktop.encoding.settings", defaultValue:"Encoding Settings…"), enabled: model.canOpenEncoding) { [weak model] in model?.openEncoding() }
    item(String(localized:"desktop.connection.information", defaultValue:"Connection Information…"), enabled: model.canOpenInformation) { [weak model] in model?.openInformation() }
    item(String(localized:"desktop.show.connection.statistics", defaultValue:"Show Connection Statistics"), enabled: model.canToggleStatistics, selected: model.showsStatistics) { [weak model] in model?.toggleStatistics() }
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
