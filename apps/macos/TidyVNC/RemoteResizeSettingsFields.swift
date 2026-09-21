// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct RemoteResizeSettingsFields: View {
  @Binding var patch: NativeRemoteResizePreferences
  let inherited: NativeRemoteResizePolicy
  let inheritance: String
  var body: some View {
    VStack(alignment:.leading,spacing:14) {
      Picker("Resize remote desktop with window",selection:Binding(get: { patch.enabled.map { $0 ? 1 : 0 } ?? -1 },set: { patch.enabled = $0 == -1 ? nil : $0 == 1 })) {
        Text("\(inheritance) (\(inherited.enabled ? "On" : "Off"))").tag(-1)
        Text("On").tag(1); Text("Off").tag(0)
      }.accessibilityIdentifier("resize.defaults.enabled")
      Text("Follows the window or the complete fullscreen display arrangement in Unscaled mode. View-only mode and servers without resize support prevent requests. Device-pixel units include the display’s backing scale.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      Toggle("Override initial desktop size",isOn:Binding(get: { patch.initialSize != nil },set: { patch.initialSize = $0 ? inherited.initialSize : nil }))
        .accessibilityIdentifier("resize.defaults.overrideSize")
      if patch.initialSize != nil {
        VStack(alignment:.leading,spacing:6) {
          Text("Initial size in remote pixels").font(.caption)
          TextField("Leave blank to use the server’s size",text:Binding(get: { patch.initialSize ?? "" },set: { patch.initialSize = $0 }))
            .textFieldStyle(.roundedBorder).accessibilityLabel("Initial desktop size").accessibilityIdentifier("resize.defaults.initialSize")
        }
      } else {
        Text("\(inheritance): \(inherited.initialSize.isEmpty ? "use the server’s size" : inherited.initialSize)")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("An optional widthxheight, such as 1920x1080, is requested once on connection when resizing is enabled. Each dimension must be 1 to 65535. An explicit blank value uses the server’s size.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      if !patch.isValid { Text("Enter a valid initial size or leave the override blank.").foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
      Text("Resizing may affect other viewers. Windowed and initial-size requests use one remote screen; fullscreen follows the selected displays.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }
  }
}

func resizeSourceLabel(_ source: NativeOptionSource) -> String {
  switch source {
  case .compiled: "Built-in default"
  case .appDefaults: "App default"
  case .profile: "Profile"
  case .session: "Connection override"
  case .document: "Connection file"
  case .commandLine: "Command line"
  }
}
