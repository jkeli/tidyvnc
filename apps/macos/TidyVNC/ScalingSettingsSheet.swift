// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct ScalingSettingsSheet: View {
  @ObservedObject var model: NativeScalingDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(String(localized:"settings.scaling.scaling.settings", defaultValue:"Scaling Settings")).font(.title2).bold()
      Text(String(localized:"settings.scaling.change.how.this.connection.s.desktop.fits.in.the.window.the.remote", defaultValue:"Change how this connection’s desktop fits in the window. The remote desktop resolution stays the same."))
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 6) {
          Text(String(localized:"settings.scaling.mode", defaultValue:"Mode")).fixedSize(horizontal: false, vertical: true)
          Picker(String(localized:"settings.scaling.mode", defaultValue:"Mode"), selection: $model.mode) {
            ForEach(NativeScalingMode.allCases, id: \.self) { mode in Text(scalingModeLabel(mode)).tag(mode) }
          }.labelsHidden().accessibilityIdentifier("scaling.mode")
        }
        source(.scaling)
        if model.mode.custom {
          TextField(model.mode == .exact ? String(localized:"settings.scaling.dimensions", defaultValue:"Dimensions") : String(localized:"settings.scaling.percentage", defaultValue:"Percentage"), text: $model.text)
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("scaling.value")
          Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 6) {
          Text(String(localized:"settings.scaling.size.units", defaultValue:"Size units")).fixedSize(horizontal: false, vertical: true)
          Picker(String(localized:"settings.scaling.size.units", defaultValue:"Size units"), selection: $model.devicePixels) {
            Text(String(localized:"settings.scaling.logical.points", defaultValue:"Logical points")).tag(false)
            Text(String(localized:"settings.scaling.device.pixels", defaultValue:"Device pixels")).tag(true)
          }.labelsHidden().disabled(model.mode.fits).accessibilityIdentifier("scaling.units")
        }
        source(.devicePixels)
        Text(model.mode.fits ? String(localized:"settings.scaling.fit.modes.always.use.the.available.window.space", defaultValue:"Fit modes always use the available window space.") : String(localized:"settings.scaling.on.a.retina.display.one.logical.point.spans.multiple.device.pixels", defaultValue:"On a Retina display, one logical point spans multiple device pixels."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
          Text(String(localized:"settings.scaling.scaling.quality", defaultValue:"Scaling quality")).fixedSize(horizontal: false, vertical: true)
          Picker(String(localized:"settings.scaling.scaling.quality", defaultValue:"Scaling quality"), selection: $model.filter) {
            Text(String(localized:"settings.scaling.nearest.neighbor", defaultValue:"Nearest neighbor")).tag(NativeScalingFilter.nearest)
            Text(String(localized:"settings.scaling.bilinear", defaultValue:"Bilinear")).tag(NativeScalingFilter.bilinear)
            Text(String(localized:"settings.scaling.area.averaging", defaultValue:"Area averaging")).tag(NativeScalingFilter.area)
          }.labelsHidden().accessibilityIdentifier("scaling.filter")
        }
        source(.filter)
        Text(filterHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 120, idealHeight: 330, maxHeight: 330)
      if let message {
        Text(message).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("scaling.error")
      }
      HStack {
        Spacer()
        Button(String(localized:"action.cancel", defaultValue:"Cancel"), role: .cancel) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        Button(String(localized:"action.apply", defaultValue:"Apply")) { if model.apply() { dismiss() } }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("scaling.apply")
      }
    }.padding(24).frame(width: 520).frame(maxHeight: 510).onDisappear { model.cancel() }
  }
  private var message: String? {
    switch model.issue {
    case .dimensions: return String(localized:"settings.scaling.this.size.exceeds.the.display.limits.choose.a.smaller.size.or.a", defaultValue:"This size exceeds the display limits. Choose a smaller size or a fit mode.")
    case .changed: return String(localized:"settings.scaling.scaling.changed.while.this.editor.was.open.close.and.reopen.it.to", defaultValue:"Scaling changed while this editor was open. Close and reopen it to use the latest settings.")
    case .closed: return String(localized:"settings.scaling.this.connection.s.scaling.settings.are.no.longer.available", defaultValue:"This connection’s scaling settings are no longer available.")
    case .invalid: return String(localized:"settings.scaling.enter.a.valid.value.for.the.selected.scaling.mode", defaultValue:"Enter a valid value for the selected scaling mode.")
    case nil: return model.candidate == nil ? String(localized:"settings.scaling.enter.a.valid.value.for.the.selected.scaling.mode", defaultValue:"Enter a valid value for the selected scaling mode.") : nil
    }
  }
  private var help: String {
    switch model.mode {
    case .exact: String(localized:"settings.scaling.width.x.height.each.from.1.to.65535.for.example.1920x1080", defaultValue:"Width x height, each from 1 to 65535. For example: 1920x1080.")
    case .independent: String(localized:"settings.scaling.width.x.height.each.from.0.01.to.10000.with.up.to", defaultValue:"Width% x height%, each from 0.01 to 10000 with up to two decimal places. For example: 125%x80%.")
    default: String(localized:"settings.scaling.from.0.01.to.10000.with.up.to.two.decimal.places.for", defaultValue:"From 0.01 to 10000, with up to two decimal places. For example: 137.5.")
    }
  }
  private var filterHelp: String {
    switch model.filter {
    case .nearest: String(localized:"settings.scaling.keeps.pixel.edges.sharp.enlarged.pixels.may.look.blocky", defaultValue:"Keeps pixel edges sharp. Enlarged pixels may look blocky.")
    case .bilinear: String(localized:"settings.scaling.blends.nearby.pixels.for.smooth.scaling.fine.details.may.soften", defaultValue:"Blends nearby pixels for smooth scaling. Fine details may soften.")
    case .area: String(localized:"settings.scaling.averages.pixels.when.shrinking.the.desktop.uses.more.processing.time", defaultValue:"Averages pixels when shrinking the desktop. Uses more processing time.")
    }
  }
  private func source(_ option: NativeScalingOption) -> some View {
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
}
