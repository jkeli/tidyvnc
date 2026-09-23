// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct RemoteResizeSettingsFields: View {
  @Binding var patch: NativeRemoteResizePreferences
  let inherited: NativeRemoteResizePolicy
  let inheritance: String
  var body: some View {
    VStack(alignment:.leading,spacing:14) {
      VStack(alignment: .leading, spacing: 6) {
        Text(String(localized:"settings.resize.resize.remote.desktop.with.window", defaultValue:"Resize remote desktop with window")).fixedSize(horizontal: false, vertical: true)
        Picker(String(localized:"settings.resize.resize.remote.desktop.with.window", defaultValue:"Resize remote desktop with window"),selection:Binding(get: { patch.enabled.map { $0 ? 1 : 0 } ?? -1 },set: { patch.enabled = $0 == -1 ? nil : $0 == 1 })) {
          Text(inheritance).tag(-1)
          Text(String(localized:"settings.input.on", defaultValue:"On")).tag(1); Text(String(localized:"settings.input.off", defaultValue:"Off")).tag(0)
        }.labelsHidden().accessibilityIdentifier("resize.defaults.enabled")
        if patch.enabled == nil {
          Text(String(localized:"settings.inheritance.effective.value", defaultValue:"Effective value: \(inherited.enabled ? String(localized:"settings.input.on", defaultValue:"On") : String(localized:"settings.input.off", defaultValue:"Off"))"))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(String(localized:"settings.resize.follows.the.window.or.the.complete.fullscreen.display.arrangement.in.unscaled.mode", defaultValue:"Follows the window or the complete fullscreen display arrangement in Unscaled mode. View-only mode and servers without resize support prevent requests. Device-pixel units include the display’s backing scale."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      Toggle(String(localized:"settings.resize.override.initial.desktop.size", defaultValue:"Override initial desktop size"),isOn:Binding(get: { patch.initialSize != nil },set: { patch.initialSize = $0 ? inherited.initialSize : nil }))
        .accessibilityIdentifier("resize.defaults.overrideSize")
      if patch.initialSize != nil {
        VStack(alignment:.leading,spacing:6) {
          Text(String(localized:"settings.resize.initial.size.in.remote.pixels", defaultValue:"Initial size in remote pixels")).font(.caption)
          Text(String(localized:"settings.resize.leave.blank.to.use.the.server.s.size", defaultValue:"Leave blank to use the server’s size")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          TextField("",text:Binding(get: { patch.initialSize ?? "" },set: { patch.initialSize = $0 }))
            .textFieldStyle(.roundedBorder).accessibilityLabel(String(localized:"settings.resize.initial.desktop.size", defaultValue:"Initial desktop size")).accessibilityIdentifier("resize.defaults.initialSize")
        }
      } else {
        Text(String(localized:"settings.resize.inherited.size", defaultValue:"\(inheritance): \(inherited.initialSize.isEmpty ? String(localized:"settings.resize.use.the.server.s.size", defaultValue:"use the server’s size") : inherited.initialSize)"))
          .font(.caption).foregroundStyle(.secondary)
      }
      Text(String(localized:"settings.resize.an.optional.widthxheight.such.as.1920x1080.is.requested.once.on.connection.when", defaultValue:"An optional widthxheight, such as 1920x1080, is requested once on connection when resizing is enabled. Each dimension must be 1 to 65535. An explicit blank value uses the server’s size."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      if !patch.isValid { Text(String(localized:"settings.resize.enter.a.valid.initial.size.or.leave.the.override.blank", defaultValue:"Enter a valid initial size or leave the override blank.")).foregroundStyle(Color.nativeWarningText).fixedSize(horizontal:false,vertical:true) }
      Text(String(localized:"settings.resize.resizing.may.affect.other.viewers.windowed.and.initial.size.requests.use.one", defaultValue:"Resizing may affect other viewers. Windowed and initial-size requests use one remote screen; fullscreen follows the selected displays."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }
  }
}

func resizeSourceLabel(_ source: NativeOptionSource) -> String {
  switch source {
  case .compiled: String(localized:"settings.defaults.built.in.default", defaultValue:"Built-in default")
  case .appDefaults: String(localized:"settings.encoding.app.default", defaultValue:"App default")
  case .profile: String(localized:"settings.encoding.profile", defaultValue:"Profile")
  case .session: String(localized:"settings.encoding.connection.override", defaultValue:"Connection override")
  case .document: String(localized:"settings.encoding.connection.file", defaultValue:"Connection file")
  case .commandLine: String(localized:"settings.encoding.command.line", defaultValue:"Command line")
  }
}
