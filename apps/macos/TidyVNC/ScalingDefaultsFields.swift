// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

func scalingModeLabel(_ mode: NativeScalingMode) -> String {
  switch mode {
  case .unscaled: "No scaling (100%)"
  case .automatic: "Fit window (stretch)"
  case .fixedRatio: "Fit window (keep proportions)"
  case .fitWidth: "Fit width"
  case .fitHeight: "Fit height"
  case .exact: "Exact dimensions"
  case .percent: "Percentage"
  case .independent: "Independent percentages"
  }
}
struct ScalingDefaultsFields: View {
  @Binding var patch: NativeScalingPreferences
  let inherited: NativeScaling
  let inheritance: String
  private var effective: NativeScaling? { try? patch.resolved(base: inherited) }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("Override desktop sizing", isOn: Binding(get: { patch.scaling != nil }, set: {
        patch.scaling = $0 ? inherited.canonical : nil
      })).accessibilityIdentifier("scalingDefaults.overrideSizing")
      if patch.scaling != nil {
        HStack {
          TextField("Scaling value", text: Binding(get: { patch.scaling ?? "" }, set: { patch.scaling = $0 }))
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("scalingDefaults.value")
          Menu("Choose Mode") {
            ForEach(NativeScalingMode.allCases, id: \.self) { mode in
              Button(scalingModeLabel(mode)) { patch.scaling = mode.initialText }
            }
          }.accessibilityIdentifier("scalingDefaults.mode")
        }
        Text("Choose a mode, or enter dimensions such as 1920x1080, a percentage such as 137.5, or independent percentages such as 125%x80%.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let effective { Text(scalingModeLabel(effective.mode)).font(.caption).foregroundStyle(.secondary) }
      } else {
        Text("\(inheritance): \(scalingModeLabel(inherited.mode)) (\(inherited.canonical)).")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Picker("Size units", selection: $patch.devicePixels) {
        Text("\(inheritance) (\(inherited.devicePixels ? "Device pixels" : "Logical points"))").tag(nil as Bool?)
        Text("Logical points").tag(false as Bool?); Text("Device pixels").tag(true as Bool?)
      }.accessibilityIdentifier("scalingDefaults.units")
      Text(effective?.mode.fits == true ? "Fit modes use the available window space. This unit preference is kept for explicit sizes." :
        "On a Retina display, one logical point spans multiple device pixels.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Picker("Scaling quality", selection: $patch.filter) {
        Text("\(inheritance) (\(quality(inherited.filter)))").tag(nil as String?)
        ForEach(NativeScalingFilter.allCases, id: \.self) { value in Text(quality(value)).tag(Optional(value.storageToken)) }
      }.accessibilityIdentifier("scalingDefaults.filter")
      Text("Scaling changes the local presentation; it does not change the remote desktop resolution. Sizes that exceed a display’s limits temporarily use a fit mode.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if effective == nil {
        Text("Enter a valid scaling value. Dimensions range from 1 to 65535; percentages range from 0.01 to 10000 with up to two decimal places.")
          .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("scalingDefaults.error")
      }
      Button(inheritance == "Use app default" ? "Use App Defaults for All Scaling Settings" : "Use Built-in Defaults for All Scaling Settings") { patch = .init() }
        .disabled(patch == NativeScalingPreferences()).accessibilityIdentifier("scalingDefaults.inherit")
    }
  }
  private func quality(_ value: NativeScalingFilter) -> String {
    switch value { case .nearest: "Nearest neighbor"; case .bilinear: "Bilinear"; case .area: "Area averaging" }
  }
}
