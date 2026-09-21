// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct InputDefaultsFields: View {
  @Binding var patch: NativeInputPreferences
  let inherited: NativeInputSettings
  let inheritance: String
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      boolean("View only", \NativeInputPreferences.viewOnly, inherited.viewOnly)
      boolean("Emulate middle mouse button", \NativeInputPreferences.emulateMiddle, inherited.emulateMiddle)
      boolean("Capture system keys in full screen", \NativeInputPreferences.fullscreenSystemKeys, inherited.fullscreenSystemKeys)
      Text("Keyboard capture requires macOS Accessibility permission and stops when the desktop loses focus.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Picker("Cursor fallback", selection: $patch.cursorFallback) {
        Text("\(inheritance) (\(cursor(inherited.cursorFallback)))").tag(nil as NativeCursorFallback?)
        ForEach(NativeCursorFallback.allCases, id: \.self) { value in Text(cursor(value)).tag(Optional(value)) }
      }.accessibilityIdentifier("inputDefaults.cursorFallback")
      Toggle("Override viewer shortcut modifiers", isOn: Binding(get: { patch.shortcutModifiers != nil }, set: {
        patch.shortcutModifiers = $0 ? inherited.shortcutModifiers.rawValue : nil
      })).accessibilityIdentifier("inputDefaults.overrideModifiers")
      HStack {
        modifier("Control", .control); modifier("Shift", .shift)
        modifier("Option", .option); modifier("Command", .command)
      }.disabled(patch.shortcutModifiers == nil)
      Text(patch.shortcutModifiers == nil ? "\(inheritance): \(modifierNames(inherited.shortcutModifiers))." :
        patch.shortcutModifiers == 0 ? "Viewer shortcuts are off. Release keyboard capture from the Connection menu." :
        "Press these modifiers alone to release keyboard capture; add G to capture, M for the connection menu, or Return for full screen.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button(inheritance == "Use app default" ? "Use App Defaults for All Input Settings" : "Use Built-in Defaults for All Input Settings") { patch = .init() }
        .disabled(patch == NativeInputPreferences()).accessibilityIdentifier("inputDefaults.inherit")
    }
  }
  private func boolean(_ title: String, _ path: WritableKeyPath<NativeInputPreferences, Bool?>, _ fallback: Bool) -> some View {
    Picker(title, selection: Binding(get: { patch[keyPath: path] }, set: { patch[keyPath: path] = $0 })) {
      Text("\(inheritance) (\(fallback ? "On" : "Off"))").tag(nil as Bool?)
      Text("On").tag(true as Bool?); Text("Off").tag(false as Bool?)
    }.accessibilityIdentifier("inputDefaults.\(title)")
  }
  private func modifier(_ title: String, _ bit: NativeShortcutModifiers) -> some View {
    Toggle(title, isOn: Binding(get: { (patch.shortcutModifiers ?? inherited.shortcutModifiers.rawValue) & bit.rawValue != 0 }, set: { selected in
      var value = patch.shortcutModifiers ?? inherited.shortcutModifiers.rawValue
      if selected { value |= bit.rawValue } else { value &= ~bit.rawValue }; patch.shortcutModifiers = value
    }))
  }
  private func cursor(_ value: NativeCursorFallback) -> String {
    switch value { case .hidden: "Hidden"; case .dot: "Dot"; case .system: "System pointer" }
  }
  private func modifierNames(_ value: NativeShortcutModifiers) -> String {
    if value.isEmpty { return "shortcuts off" }
    return [(NativeShortcutModifiers.control,"Control"),(.shift,"Shift"),(.option,"Option"),(.command,"Command")]
      .filter { value.contains($0.0) }.map(\.1).joined(separator: "+")
  }
}
