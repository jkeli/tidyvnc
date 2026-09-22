// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct InputSettingsSheet: View {
  @ObservedObject var model: NativeInputDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(String(localized:"settings.input.input.settings", defaultValue:"Input Settings")).font(.title2).bold()
      Text(String(localized:"settings.input.these.settings.apply.to.this.connection", defaultValue:"These settings apply to this connection.")).foregroundStyle(.secondary)
      ScrollView {
      Form {
        Toggle(String(localized:"settings.input.view.only", defaultValue:"View only"), isOn: $model.viewOnly).accessibilityIdentifier("input.viewOnly")
        source(.viewOnly)
        Text(String(localized:"settings.input.watch.the.remote.desktop.without.sending.keyboard.pointer.or.clipboard.input.enabling", defaultValue:"Watch the remote desktop without sending keyboard, pointer or clipboard input. Enabling this releases held keys and mouse buttons."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Toggle(String(localized:"settings.input.emulate.middle.mouse.button", defaultValue:"Emulate middle mouse button"), isOn: $model.emulateMiddle).accessibilityIdentifier("input.emulateMiddle")
        source(.emulateMiddle)
        Text(String(localized:"settings.input.press.the.left.and.right.mouse.buttons.together.for.a.middle.click", defaultValue:"Press the left and right mouse buttons together for a middle click. Single-button presses wait briefly for the second button."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Toggle(String(localized:"settings.input.capture.system.keys.in.full.screen", defaultValue:"Capture system keys in full screen"), isOn: $model.fullscreenSystemKeys)
          .accessibilityIdentifier("input.fullscreenSystemKeys")
        source(.fullscreenSystemKeys)
        Text(String(localized:"settings.input.requires.macos.accessibility.permission.keyboard.capture.stops.when.this.desktop.loses.focus", defaultValue:"Requires macOS Accessibility permission. Keyboard capture stops when this desktop loses focus."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 8) {
          Text(String(localized:"settings.input.viewer.shortcut.modifiers", defaultValue:"Viewer shortcut modifiers"))
          LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading) {
            modifier(String(localized:"settings.input.control", defaultValue:"Control"), .control); modifier(String(localized:"settings.input.shift", defaultValue:"Shift"), .shift)
            modifier(String(localized:"settings.input.option", defaultValue:"Option"), .option); modifier(String(localized:"settings.input.command", defaultValue:"Command"), .command)
          }
          source(.shortcutModifiers)
          Text(shortcutHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("input.shortcutModifiers")
        VStack(alignment: .leading, spacing: 6) {
          Text(String(localized:"settings.input.cursor.fallback", defaultValue:"Cursor fallback")).fixedSize(horizontal: false, vertical: true)
          Picker(String(localized:"settings.input.cursor.fallback", defaultValue:"Cursor fallback"), selection: $model.cursorFallback) {
            Text(String(localized:"settings.input.hidden", defaultValue:"Hidden")).tag(NativeCursorFallback.hidden)
            Text(String(localized:"settings.input.dot", defaultValue:"Dot")).tag(NativeCursorFallback.dot)
            Text(String(localized:"settings.input.system.pointer", defaultValue:"System pointer")).tag(NativeCursorFallback.system)
          }.labelsHidden().accessibilityIdentifier("input.cursorFallback")
        }
        source(.cursorFallback)
        Text(String(localized:"settings.input.used.when.the.server.supplies.no.visible.cursor.view.only.mode.always", defaultValue:"Used when the server supplies no visible cursor. View-only mode always uses the system pointer."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 180, idealHeight: 500, maxHeight: 500)
      if let message {
        Text(message).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("input.error")
      }
      HStack {
        Spacer()
        Button(String(localized:"action.cancel", defaultValue:"Cancel"), role: .cancel) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        Button(String(localized:"action.apply", defaultValue:"Apply")) { if model.apply() { dismiss() } }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("input.apply")
      }
    }.padding(24).frame(width: 520).frame(maxHeight: 700).onDisappear { model.cancel() }
  }
  private func source(_ option: NativeInputOption) -> some View {
    let label: String
    switch model.source(for: option) {
    case .compiled: label = String(localized:"settings.defaults.built.in.default", defaultValue:"Built-in default")
    case .appDefaults: label = String(localized:"settings.encoding.app.default", defaultValue:"App default")
    case .profile: label = String(localized:"settings.input.saved.profile.override", defaultValue:"Saved profile override")
    case .session: label = String(localized:"settings.input.this.connection.override", defaultValue:"This connection override")
    case .document: label = String(localized:"settings.encoding.connection.file", defaultValue:"Connection file")
    case .commandLine: label = String(localized:"settings.input.command.line.override", defaultValue:"Command-line override")
    }
    return Text(label).font(.caption).foregroundStyle(.secondary)
  }
  private func modifier(_ label: String, _ bit: NativeShortcutModifiers) -> some View {
    Toggle(label, isOn: Binding(get: { model.shortcutModifiers.contains(bit) }, set: { selected in
      if selected { model.shortcutModifiers.insert(bit) } else { model.shortcutModifiers.remove(bit) }
    })).accessibilityIdentifier("input.modifier.\(bit.rawValue)")
  }
  private var shortcutHelp: String {
    if model.shortcutModifiers.isEmpty { return String(localized:"settings.input.viewer.shortcuts.are.off.use.the.connection.menu.to.release.keyboard.capture", defaultValue:"Viewer shortcuts are off. Use the Connection menu to release keyboard capture.") }
    let prefix = [(NativeShortcutModifiers.control,"⌃"),(.shift,"⇧"),(.option,"⌥"),(.command,"⌘")]
      .filter { model.shortcutModifiers.contains($0.0) }.map(\.1).joined()
    return String(localized:"settings.input.shortcut.instructions", defaultValue:"\(prefix) alone releases keyboard capture. Add G to capture, M for the connection menu, or Return for full screen. Add Space, release Space, then press a key to send that combination to the remote desktop.")
  }
  private var message: String? {
    switch model.issue {
    case .changed: String(localized:"settings.input.input.settings.changed.while.this.editor.was.open.close.and.reopen.it", defaultValue:"Input settings changed while this editor was open. Close and reopen it to use the latest settings.")
    case .closed: String(localized:"settings.input.this.connection.s.input.settings.are.no.longer.available", defaultValue:"This connection’s input settings are no longer available.")
    case .failed: String(localized:"settings.input.input.settings.could.not.be.applied.close.and.reopen.the.editor.to", defaultValue:"Input settings could not be applied. Close and reopen the editor to try again.")
    case nil: nil
    }
  }
}
