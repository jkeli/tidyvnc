// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct ScalingSettingsSheet: View {
  @ObservedObject var model: NativeScalingDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Scaling Settings").font(.title2).bold()
      Text("Change how this connection’s desktop fits in the window. The remote desktop resolution stays the same.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Form {
        Picker("Mode", selection: $model.mode) {
          ForEach(NativeScalingMode.allCases, id: \.self) { mode in Text(scalingModeLabel(mode)).tag(mode) }
        }.accessibilityIdentifier("scaling.mode")
        source(.scaling)
        if model.mode.custom {
          TextField(model.mode == .exact ? "Dimensions" : "Percentage", text: $model.text)
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("scaling.value")
          Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Picker("Size units", selection: $model.devicePixels) {
          Text("Logical points").tag(false)
          Text("Device pixels").tag(true)
        }.disabled(model.mode.fits).accessibilityIdentifier("scaling.units")
        source(.devicePixels)
        Text(model.mode.fits ? "Fit modes always use the available window space." : "On a Retina display, one logical point spans multiple device pixels.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Picker("Scaling quality", selection: $model.filter) {
          Text("Nearest neighbor").tag(NativeScalingFilter.nearest)
          Text("Bilinear").tag(NativeScalingFilter.bilinear)
          Text("Area averaging").tag(NativeScalingFilter.area)
        }.accessibilityIdentifier("scaling.filter")
        source(.filter)
        Text(filterHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if let message {
        Text(message).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("scaling.error")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        Button("Apply") { if model.apply() { dismiss() } }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("scaling.apply")
      }
    }.padding(24).frame(width: 520).onDisappear { model.cancel() }
  }
  private var message: String? {
    switch model.issue {
    case .dimensions: return "This size exceeds the display limits. Choose a smaller size or a fit mode."
    case .changed: return "Scaling changed while this editor was open. Close and reopen it to use the latest settings."
    case .closed: return "This connection’s scaling settings are no longer available."
    case .invalid: return "Enter a valid value for the selected scaling mode."
    case nil: return model.candidate == nil ? "Enter a valid value for the selected scaling mode." : nil
    }
  }
  private var help: String {
    switch model.mode {
    case .exact: "Width x height, each from 1 to 65535. For example: 1920x1080."
    case .independent: "Width% x height%, each from 0.01 to 10000 with up to two decimal places. For example: 125%x80%."
    default: "From 0.01 to 10000, with up to two decimal places. For example: 137.5."
    }
  }
  private var filterHelp: String {
    switch model.filter {
    case .nearest: "Keeps pixel edges sharp. Enlarged pixels may look blocky."
    case .bilinear: "Blends nearby pixels for smooth scaling. Fine details may soften."
    case .area: "Averages pixels when shrinking the desktop. Uses more processing time."
    }
  }
  private func source(_ option: NativeScalingOption) -> some View {
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
}
