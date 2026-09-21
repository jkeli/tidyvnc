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
      Picker("Start in full screen",selection:$patch.startsFullscreen) {
        Text("\(inheritance) (\(inherited.startsFullscreen ? "On" : "Off"))").tag(nil as Bool?)
        Text("On").tag(true as Bool?); Text("Off").tag(false as Bool?)
      }.accessibilityIdentifier("fullscreen.defaults.start")
      Picker("Use",selection:$patch.mode) {
        Text("\(inheritance) (\(inherited.mode.title))").tag(nil as String?)
        ForEach(NativeFullscreenMode.allCases,id:\.self) { Text($0.title).tag($0.rawValue as String?) }
      }.accessibilityIdentifier("fullscreen.defaults.mode")
      Toggle("Override selected displays",isOn:Binding(get:{ patch.selectedDisplays != nil },set:{ patch.selectedDisplays = $0 ? selected : nil }))
        .accessibilityIdentifier("fullscreen.defaults.overrideDisplays")
      ScrollView {
        VStack(alignment:.leading,spacing:8) {
          ForEach(displays.snapshot.displays,id:\.id) { display in
            Toggle(display.name,isOn:includes(display.id.rawValue)).toggleStyle(.checkbox)
          }
          ForEach(Array(selected.filter { displays.snapshot.display(.init($0)) == nil }.enumerated()),id:\.element) { index,id in
            Toggle("Disconnected selected display \(index+1)",isOn:includes(id)).toggleStyle(.checkbox)
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.frame(height:90).disabled(patch.selectedDisplays == nil)
      if displays.snapshot.error != nil { Text("Display information is unavailable. Saved selections are kept.").foregroundStyle(.orange) }
      if (try? patch.resolved(base:inherited)) == nil {
        Text("Selected displays mode requires at least one selected display.").foregroundStyle(.orange)
      }
      Text("Selections are kept when displays disconnect. If none are available, the current display is used temporarily. These settings apply to new connection windows.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }.onAppear { displays.refresh() }
  }
}
