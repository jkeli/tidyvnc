// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct FullscreenDefaultsFields: View {
  @Binding var patch: NativeFullscreenPreferences
  let inherited: NativeFullscreenPolicy
  let inheritance: String
  @StateObject private var displays = NativeDisplayService()
  private var selected: [String] { patch.selectedDisplays ?? inherited.selectedDisplays.map(\.rawValue) }
  private func includes(_ id: String) -> Binding<Bool> {
    Binding(get:{ selected.contains(id) },set:{ value in
      var ids = Set(selected); if value { ids.insert(id) } else { ids.remove(id) }
      patch.selectedDisplays = ids.sorted()
    })
  }
  var body: some View {
    VStack(alignment:.leading,spacing:12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(String(localized:"settings.fullscreen.start.in.full.screen", defaultValue:"Start in full screen")).fixedSize(horizontal: false, vertical: true)
        Picker(String(localized:"settings.fullscreen.start.in.full.screen", defaultValue:"Start in full screen"),selection:$patch.startsFullscreen) {
          Text(inheritance).tag(nil as Bool?)
          Text(String(localized:"settings.input.on", defaultValue:"On")).tag(true as Bool?); Text(String(localized:"settings.input.off", defaultValue:"Off")).tag(false as Bool?)
        }.labelsHidden().accessibilityIdentifier("fullscreen.defaults.start")
        if patch.startsFullscreen == nil {
          Text(String(localized:"settings.inheritance.effective.value", defaultValue:"Effective value: \(inherited.startsFullscreen ? String(localized:"settings.input.on", defaultValue:"On") : String(localized:"settings.input.off", defaultValue:"Off"))"))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(String(localized:"settings.fullscreen.use", defaultValue:"Use")).fixedSize(horizontal: false, vertical: true)
        Picker(String(localized:"settings.fullscreen.use", defaultValue:"Use"),selection:$patch.mode) {
          Text(inheritance).tag(nil as String?)
          ForEach(NativeFullscreenMode.allCases,id:\.self) { Text($0.title).tag($0.rawValue as String?) }
        }.labelsHidden().accessibilityIdentifier("fullscreen.defaults.mode")
        if patch.mode == nil {
          Text(String(localized:"settings.inheritance.effective.value", defaultValue:"Effective value: \(inherited.mode.title)"))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Toggle(String(localized:"settings.fullscreen.override.selected.displays", defaultValue:"Override selected displays"),isOn:Binding(get:{ patch.selectedDisplays != nil },set:{ patch.selectedDisplays = $0 ? selected : nil }))
        .accessibilityIdentifier("fullscreen.defaults.overrideDisplays")
      ScrollView {
        VStack(alignment:.leading,spacing:8) {
          ForEach(displays.snapshot.displays,id:\.id) { display in
            Toggle(display.name,isOn:includes(display.id.rawValue)).toggleStyle(.checkbox)
          }
          ForEach(Array(selected.filter { displays.snapshot.display(.init($0)) == nil }.enumerated()),id:\.element) { index,id in
            Toggle(String(localized:"settings.display.disconnected.selection", defaultValue:"Disconnected selected display \((index+1).formatted())"),isOn:includes(id)).toggleStyle(.checkbox)
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.frame(height:90).disabled(patch.selectedDisplays == nil)
      if displays.snapshot.error != nil { Text(String(localized:"settings.fullscreen.display.information.is.unavailable.saved.selections.are.kept", defaultValue:"Display information is unavailable. Saved selections are kept.")).foregroundStyle(.orange) }
      if (try? patch.resolved(base:inherited)) == nil {
        Text(String(localized:"settings.fullscreen.selected.displays.mode.requires.at.least.one.selected.display", defaultValue:"Selected displays mode requires at least one selected display.")).foregroundStyle(.orange)
      }
      Text(String(localized:"settings.fullscreen.selections.are.kept.when.displays.disconnect.if.none.are.available.the.current", defaultValue:"Selections are kept when displays disconnect. If none are available, the current display is used temporarily. These settings apply to new connection windows."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }.onAppear { displays.refresh() }
  }
}
