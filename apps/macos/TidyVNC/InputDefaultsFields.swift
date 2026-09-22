// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct InputDefaultsFields: View {
  @Binding var patch: NativeInputPreferences
  let inherited: NativeInputSettings
  let inheritance: String
  var resetSource: NativeOptionSource = .compiled
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      boolean(String(localized:"settings.input.view.only", defaultValue:"View only"), \NativeInputPreferences.viewOnly, inherited.viewOnly, id: "viewOnly")
      boolean(String(localized:"settings.input.emulate.middle.mouse.button", defaultValue:"Emulate middle mouse button"), \NativeInputPreferences.emulateMiddle, inherited.emulateMiddle, id: "emulateMiddle")
      boolean(String(localized:"settings.input.capture.system.keys.in.full.screen", defaultValue:"Capture system keys in full screen"), \NativeInputPreferences.fullscreenSystemKeys, inherited.fullscreenSystemKeys, id: "fullscreenSystemKeys")
      Text(String(localized:"settings.input.keyboard.capture.requires.macos.accessibility.permission.and.stops.when.the.desktop.loses", defaultValue:"Keyboard capture requires macOS Accessibility permission and stops when the desktop loses focus."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        Text(String(localized:"settings.input.cursor.fallback", defaultValue:"Cursor fallback")).fixedSize(horizontal: false, vertical: true)
        Picker(String(localized:"settings.input.cursor.fallback", defaultValue:"Cursor fallback"), selection: $patch.cursorFallback) {
          Text(inheritance).tag(nil as NativeCursorFallback?)
          ForEach(NativeCursorFallback.allCases, id: \.self) { value in Text(cursor(value)).tag(Optional(value)) }
        }.labelsHidden().accessibilityIdentifier("inputDefaults.cursorFallback")
        if patch.cursorFallback == nil {
          Text(String(localized:"settings.inheritance.effective.value", defaultValue:"Effective value: \(cursor(inherited.cursorFallback))"))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Toggle(String(localized:"settings.input.override.viewer.shortcut.modifiers", defaultValue:"Override viewer shortcut modifiers"), isOn: Binding(get: { patch.shortcutModifiers != nil }, set: {
        patch.shortcutModifiers = $0 ? inherited.shortcutModifiers.rawValue : nil
      })).accessibilityIdentifier("inputDefaults.overrideModifiers")
      LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading) {
        modifier(String(localized:"settings.input.control", defaultValue:"Control"), .control); modifier(String(localized:"settings.input.shift", defaultValue:"Shift"), .shift)
        modifier(String(localized:"settings.input.option", defaultValue:"Option"), .option); modifier(String(localized:"settings.input.command", defaultValue:"Command"), .command)
      }.disabled(patch.shortcutModifiers == nil)
      Text(patch.shortcutModifiers == nil ? String(localized:"settings.input.inherited.modifiers", defaultValue:"\(inheritance): \(modifierNames(inherited.shortcutModifiers)).") :
        patch.shortcutModifiers == 0 ? String(localized:"settings.input.viewer.shortcuts.are.off.release.keyboard.capture.from.the.connection.menu", defaultValue:"Viewer shortcuts are off. Release keyboard capture from the Connection menu.") :
        String(localized:"settings.input.press.these.modifiers.alone.to.release.keyboard.capture.add.g.to.capture", defaultValue:"Press these modifiers alone to release keyboard capture; add G to capture, M for the connection menu, or Return for full screen."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button(resetSource == .appDefaults ? String(localized:"settings.inheritance.use.app.defaults", defaultValue:"Use App Defaults") : String(localized:"settings.inheritance.use.builtin.defaults", defaultValue:"Use Built-in Defaults")) { patch = .init() }
        .disabled(patch == NativeInputPreferences()).accessibilityIdentifier("inputDefaults.inherit")
    }
  }
  private func boolean(_ title: String, _ path: WritableKeyPath<NativeInputPreferences, Bool?>, _ fallback: Bool, id: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).fixedSize(horizontal: false, vertical: true)
      Picker(title, selection: Binding(get: { patch[keyPath: path] }, set: { patch[keyPath: path] = $0 })) {
        Text(inheritance).tag(nil as Bool?)
        Text(String(localized:"settings.input.on", defaultValue:"On")).tag(true as Bool?); Text(String(localized:"settings.input.off", defaultValue:"Off")).tag(false as Bool?)
      }.labelsHidden().accessibilityIdentifier("inputDefaults.\(id)")
      if patch[keyPath: path] == nil {
        Text(String(localized:"settings.inheritance.effective.value", defaultValue:"Effective value: \(fallback ? String(localized:"settings.input.on", defaultValue:"On") : String(localized:"settings.input.off", defaultValue:"Off"))"))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
  private func modifier(_ title: String, _ bit: NativeShortcutModifiers) -> some View {
    Toggle(title, isOn: Binding(get: { (patch.shortcutModifiers ?? inherited.shortcutModifiers.rawValue) & bit.rawValue != 0 }, set: { selected in
      var value = patch.shortcutModifiers ?? inherited.shortcutModifiers.rawValue
      if selected { value |= bit.rawValue } else { value &= ~bit.rawValue }; patch.shortcutModifiers = value
    }))
  }
  private func cursor(_ value: NativeCursorFallback) -> String {
    switch value { case .hidden: String(localized:"settings.input.hidden", defaultValue:"Hidden"); case .dot: String(localized:"settings.input.dot", defaultValue:"Dot"); case .system: String(localized:"settings.input.system.pointer", defaultValue:"System pointer") }
  }
  private func modifierNames(_ value: NativeShortcutModifiers) -> String {
    if value.isEmpty { return String(localized:"settings.input.shortcuts.off", defaultValue:"shortcuts off") }
    return [(NativeShortcutModifiers.control,String(localized:"settings.input.control", defaultValue:"Control")),(.shift,String(localized:"settings.input.shift", defaultValue:"Shift")),(.option,String(localized:"settings.input.option", defaultValue:"Option")),(.command,String(localized:"settings.input.command", defaultValue:"Command"))]
      .filter { value.contains($0.0) }.map(\.1).joined(separator: "+")
  }
}
