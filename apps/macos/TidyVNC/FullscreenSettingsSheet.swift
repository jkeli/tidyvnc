// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct FullscreenSettingsSheet: View {
  @ObservedObject var model: NativeFullscreenDraft
  let dismiss: () -> Void
  private var displays: [NativeDisplay] { model.snapshot?.displays ?? [] }
  private var extent: CGRect { displays.reduce(.null) { $0.union(CGRect(x:$1.bounds.x,y:$1.bounds.y,width:$1.bounds.width,height:$1.bounds.height)) } }
  private func selected(_ id: NativeDisplayID) -> Binding<Bool> {
    Binding(get:{ model.selectedDisplays.contains(id) },set:{ if $0 { model.selectedDisplays.insert(id) } else { model.selectedDisplays.remove(id) } })
  }
  private func tile(_ display: NativeDisplay, index: Int, size: CGSize) -> some View {
    let bounds = extent
    let factor = min((size.width-12)/max(1,bounds.width),(size.height-12)/max(1,bounds.height))
    let chosen = model.chosenDisplays.contains { $0.id == display.id }
    return RoundedRectangle(cornerRadius:4).fill(chosen ? Color.accentColor : Color.secondary.opacity(0.2))
      .overlay(Text(verbatim:(index+1).formatted()).font(.headline).foregroundStyle(chosen ? Color.white : Color.primary))
      .frame(width:max(2,display.bounds.width*factor-3),height:max(2,display.bounds.height*factor-3))
      .position(x:(size.width-bounds.width*factor)/2+(display.bounds.x-bounds.minX+display.bounds.width/2)*factor,
                y:(size.height-bounds.height*factor)/2+(display.bounds.y-bounds.minY+display.bounds.height/2)*factor)
      .onTapGesture { if model.mode == .selected { selected(display.id).wrappedValue.toggle() } }
  }
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(String(localized:"settings.fullscreen.fullscreen.displays", defaultValue:"Fullscreen Displays")).font(.title2).bold()
      Text(String(localized:"settings.fullscreen.choose.where.this.connection.appears.when.you.enter.full.screen.exit.full", defaultValue:"Choose where this connection appears when you enter full screen. Exit Full Screen returns to this window."))
        .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Toggle(String(localized:"settings.fullscreen.start.in.full.screen", defaultValue:"Start in full screen"),isOn:$model.startsFullscreen)
            .accessibilityIdentifier("fullscreen.start")
          Text(fullscreenSourceLabel(model.source(.startsFullscreen))).font(.caption).foregroundStyle(.secondary)
          Picker(String(localized:"settings.fullscreen.use", defaultValue:"Use"),selection:$model.mode) {
            ForEach(NativeFullscreenMode.allCases,id:\.self) { Text($0.title).tag($0) }
          }.accessibilityIdentifier("fullscreen.mode")
          Text(fullscreenSourceLabel(model.source(.mode))).font(.caption).foregroundStyle(.secondary)
          if !displays.isEmpty && extent.width.isFinite && extent.height.isFinite {
            GeometryReader { geometry in
              ForEach(Array(displays.enumerated()),id:\.element.id) { index, display in tile(display,index:index,size:geometry.size) }
            }.frame(height:110)
            .environment(\.layoutDirection, .leftToRight).accessibilityHidden(true)
          }
          VStack(alignment:.leading,spacing:8) {
            ForEach(Array(displays.enumerated()),id:\.element.id) { index, display in
              let label = String(localized:"settings.display.description", defaultValue:"\((index+1).formatted()). \(display.name) — \(display.bounds.width.formatted(.number.precision(.fractionLength(0)))) × \(display.bounds.height.formatted(.number.precision(.fractionLength(0)))) points, \(display.backingScale.formatted())×")
              if model.mode == .selected { Toggle(label,isOn:selected(display.id)).toggleStyle(.checkbox) }
              else { Text(label) }
            }
            if model.mode == .selected {
              ForEach(Array(model.missing.enumerated()),id:\.element) { index, id in
                Toggle(String(localized:"settings.display.disconnected.selection", defaultValue:"Disconnected selected display \((index+1).formatted())"),isOn:selected(id)).toggleStyle(.checkbox)
              }
            }
          }.frame(maxWidth:.infinity,alignment:.leading)
          Text(String(localized:"settings.fullscreen.selected.source", defaultValue:"Selected displays: \(fullscreenSourceLabel(model.source(.selectedDisplays)))")).font(.caption).foregroundStyle(.secondary)
          if model.mode == .selected && !model.missing.isEmpty {
            Text(String(localized:"settings.fullscreen.disconnected.selections.are.kept.available.selected.displays.are.used.if.none.remain", defaultValue:"Disconnected selections are kept. Available selected displays are used; if none remain, the current display is used temporarily."))
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
          }
          Text(String(localized:"settings.fullscreen.display.changes.apply.the.next.time.full.screen.opens.reconnecting.restores.full", defaultValue:"Display changes apply the next time full screen opens. Reconnecting restores full screen if it was active at disconnect. Changing the startup option overrides that behavior for the next connection."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 100, idealHeight: 470, maxHeight: 470)
      if let message = model.validationMessage ?? model.message {
        Text(message).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("fullscreen.issue")
      }
      Button(String(localized:"settings.fullscreen.restore.initial.settings", defaultValue:"Restore Initial Settings")) { model.restoreInitial() }
        Button(String(localized:"settings.fullscreen.review.displays", defaultValue:"Review Displays")) { model.reviewDisplays() }.disabled(!model.needsReview)
      HStack {
        Spacer()
        Button(String(localized:"action.cancel", defaultValue:"Cancel"),role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(String(localized:"action.apply", defaultValue:"Apply")) { if model.apply() { dismiss() } }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width:520).frame(maxHeight:730)
  }
}

private func fullscreenSourceLabel(_ source: NativeOptionSource) -> String {
  switch source {
  case .compiled: String(localized:"settings.defaults.built.in.default", defaultValue:"Built-in default")
  case .appDefaults: String(localized:"settings.encoding.app.default", defaultValue:"App default")
  case .profile: String(localized:"settings.encoding.profile", defaultValue:"Profile")
  case .session: String(localized:"settings.encoding.connection.override", defaultValue:"Connection override")
  case .document: String(localized:"settings.encoding.connection.file", defaultValue:"Connection file")
  case .commandLine: String(localized:"settings.encoding.command.line", defaultValue:"Command line")
  }
}
