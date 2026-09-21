// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct InputSettingsSheet: View {
  @ObservedObject var model: NativeInputDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Input Settings").font(.title2).bold()
      Text("These settings apply to this connection.").foregroundStyle(.secondary)
      Form {
        Toggle("View only", isOn: $model.viewOnly).accessibilityIdentifier("input.viewOnly")
        source(.viewOnly)
        Text("Watch the remote desktop without sending keyboard, pointer or clipboard input. Enabling this releases held keys and mouse buttons.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Toggle("Emulate middle mouse button", isOn: $model.emulateMiddle).accessibilityIdentifier("input.emulateMiddle")
        source(.emulateMiddle)
        Text("Press the left and right mouse buttons together for a middle click. Single-button presses wait briefly for the second button.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Toggle("Capture system keys in full screen", isOn: $model.fullscreenSystemKeys)
          .accessibilityIdentifier("input.fullscreenSystemKeys")
        source(.fullscreenSystemKeys)
        Text("Requires macOS Accessibility permission. Keyboard capture stops when this desktop loses focus.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 8) {
          Text("Viewer shortcut modifiers")
          HStack {
            modifier("Control", .control); modifier("Shift", .shift)
            modifier("Option", .option); modifier("Command", .command)
          }
          source(.shortcutModifiers)
          Text(shortcutHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("input.shortcutModifiers")
        Picker("Cursor fallback", selection: $model.cursorFallback) {
          Text("Hidden").tag(NativeCursorFallback.hidden)
          Text("Dot").tag(NativeCursorFallback.dot)
          Text("System pointer").tag(NativeCursorFallback.system)
        }.accessibilityIdentifier("input.cursorFallback")
        source(.cursorFallback)
        Text("Used when the server supplies no visible cursor. View-only mode always uses the system pointer.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if let message {
        Text(message).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("input.error")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        Button("Apply") { if model.apply() { dismiss() } }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("input.apply")
      }
    }.padding(24).frame(width: 520).onDisappear { model.cancel() }
  }
  private func source(_ option: NativeInputOption) -> some View {
    let label: String
    switch model.source(for: option) {
    case .compiled: label = "Built-in default"
    case .appDefaults: label = "App default"
    case .profile: label = "Saved profile override"
    case .session: label = "This connection override"
    case .document: label = "Connection file"
    case .commandLine: label = "Command-line override"
    }
    return Text(label).font(.caption).foregroundStyle(.secondary)
  }
  private func modifier(_ label: String, _ bit: NativeShortcutModifiers) -> some View {
    Toggle(label, isOn: Binding(get: { model.shortcutModifiers.contains(bit) }, set: { selected in
      if selected { model.shortcutModifiers.insert(bit) } else { model.shortcutModifiers.remove(bit) }
    })).accessibilityIdentifier("input.modifier.\(bit.rawValue)")
  }
  private var shortcutHelp: String {
    if model.shortcutModifiers.isEmpty { return "Viewer shortcuts are off. Use the Connection menu to release keyboard capture." }
    let prefix = [(NativeShortcutModifiers.control,"⌃"),(.shift,"⇧"),(.option,"⌥"),(.command,"⌘")]
      .filter { model.shortcutModifiers.contains($0.0) }.map(\.1).joined()
    return "\(prefix) alone releases keyboard capture. Add G to capture, M for the connection menu, or Return for full screen. Add Space, release Space, then press a key to send that combination to the remote desktop."
  }
  private var message: String? {
    switch model.issue {
    case .changed: "Input settings changed while this editor was open. Close and reopen it to use the latest settings."
    case .closed: "This connection’s input settings are no longer available."
    case .failed: "Input settings could not be applied. Close and reopen the editor to try again."
    case nil: nil
    }
  }
}
