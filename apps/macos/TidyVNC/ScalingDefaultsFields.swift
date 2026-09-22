// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

func scalingModeLabel(_ mode: NativeScalingMode) -> String {
  switch mode {
  case .unscaled: String(localized:"settings.scaling.no.scaling.100", defaultValue:"No scaling (100%)")
  case .automatic: String(localized:"settings.scaling.fit.window.stretch", defaultValue:"Fit window (stretch)")
  case .fixedRatio: String(localized:"settings.scaling.fit.window.keep.proportions", defaultValue:"Fit window (keep proportions)")
  case .fitWidth: String(localized:"settings.scaling.fit.width", defaultValue:"Fit width")
  case .fitHeight: String(localized:"settings.scaling.fit.height", defaultValue:"Fit height")
  case .exact: String(localized:"settings.scaling.exact.dimensions", defaultValue:"Exact dimensions")
  case .percent: String(localized:"settings.scaling.percentage", defaultValue:"Percentage")
  case .independent: String(localized:"settings.scaling.independent.percentages", defaultValue:"Independent percentages")
  }
}
struct ScalingDefaultsFields: View {
  @Binding var patch: NativeScalingPreferences
  let inherited: NativeScaling
  let inheritance: String
  var resetSource: NativeOptionSource = .compiled
  private var effective: NativeScaling? { try? patch.resolved(base: inherited) }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(String(localized:"settings.scaling.override.desktop.sizing", defaultValue:"Override desktop sizing"), isOn: Binding(get: { patch.scaling != nil }, set: {
        patch.scaling = $0 ? inherited.canonical : nil
      })).accessibilityIdentifier("scalingDefaults.overrideSizing")
      if patch.scaling != nil {
        HStack {
          TextField(String(localized:"settings.scaling.scaling.value", defaultValue:"Scaling value"), text: Binding(get: { patch.scaling ?? "" }, set: { patch.scaling = $0 }))
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("scalingDefaults.value")
          Menu(String(localized:"settings.scaling.choose.mode", defaultValue:"Choose Mode")) {
            ForEach(NativeScalingMode.allCases, id: \.self) { mode in
              Button(scalingModeLabel(mode)) { patch.scaling = mode.initialText }
            }
          }.accessibilityIdentifier("scalingDefaults.mode")
        }
        Text(String(localized:"settings.scaling.choose.a.mode.or.enter.dimensions.such.as.1920x1080.a.percentage.such", defaultValue:"Choose a mode, or enter dimensions such as 1920x1080, a percentage such as 137.5, or independent percentages such as 125%x80%."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let effective { Text(scalingModeLabel(effective.mode)).font(.caption).foregroundStyle(.secondary) }
      } else {
        Text(String(localized:"settings.scaling.inherited.mode", defaultValue:"\(inheritance): \(scalingModeLabel(inherited.mode)) (\(inherited.canonical))."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(String(localized:"settings.scaling.size.units", defaultValue:"Size units")).fixedSize(horizontal: false, vertical: true)
        Picker(String(localized:"settings.scaling.size.units", defaultValue:"Size units"), selection: $patch.devicePixels) {
          Text(inheritance).tag(nil as Bool?)
          Text(String(localized:"settings.scaling.logical.points", defaultValue:"Logical points")).tag(false as Bool?); Text(String(localized:"settings.scaling.device.pixels", defaultValue:"Device pixels")).tag(true as Bool?)
        }.labelsHidden().accessibilityIdentifier("scalingDefaults.units")
        if patch.devicePixels == nil {
          Text(String(localized:"settings.inheritance.effective.value", defaultValue:"Effective value: \(inherited.devicePixels ? String(localized:"settings.scaling.device.pixels", defaultValue:"Device pixels") : String(localized:"settings.scaling.logical.points", defaultValue:"Logical points"))"))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(effective?.mode.fits == true ? String(localized:"settings.scaling.fit.modes.use.the.available.window.space.this.unit.preference.is.kept", defaultValue:"Fit modes use the available window space. This unit preference is kept for explicit sizes.") :
        String(localized:"settings.scaling.on.a.retina.display.one.logical.point.spans.multiple.device.pixels", defaultValue:"On a Retina display, one logical point spans multiple device pixels."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        Text(String(localized:"settings.scaling.scaling.quality", defaultValue:"Scaling quality")).fixedSize(horizontal: false, vertical: true)
        Picker(String(localized:"settings.scaling.scaling.quality", defaultValue:"Scaling quality"), selection: $patch.filter) {
          Text(inheritance).tag(nil as String?)
          ForEach(NativeScalingFilter.allCases, id: \.self) { value in Text(quality(value)).tag(Optional(value.storageToken)) }
        }.labelsHidden().accessibilityIdentifier("scalingDefaults.filter")
        if patch.filter == nil {
          Text(String(localized:"settings.inheritance.effective.value", defaultValue:"Effective value: \(quality(inherited.filter))"))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(String(localized:"settings.scaling.scaling.changes.the.local.presentation.it.does.not.change.the.remote.desktop", defaultValue:"Scaling changes the local presentation; it does not change the remote desktop resolution. Sizes that exceed a display’s limits temporarily use a fit mode."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if effective == nil {
        Text(String(localized:"settings.scaling.enter.a.valid.scaling.value.dimensions.range.from.1.to.65535.percentages", defaultValue:"Enter a valid scaling value. Dimensions range from 1 to 65535; percentages range from 0.01 to 10000 with up to two decimal places."))
          .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("scalingDefaults.error")
      }
      Button(resetSource == .appDefaults ? String(localized:"settings.inheritance.use.app.defaults", defaultValue:"Use App Defaults") : String(localized:"settings.inheritance.use.builtin.defaults", defaultValue:"Use Built-in Defaults")) { patch = .init() }
        .disabled(patch == NativeScalingPreferences()).accessibilityIdentifier("scalingDefaults.inherit")
    }
  }
  private func quality(_ value: NativeScalingFilter) -> String {
    switch value { case .nearest: String(localized:"settings.scaling.nearest.neighbor", defaultValue:"Nearest neighbor"); case .bilinear: String(localized:"settings.scaling.bilinear", defaultValue:"Bilinear"); case .area: String(localized:"settings.scaling.area.averaging", defaultValue:"Area averaging") }
  }
}
