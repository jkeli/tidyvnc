// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct RemoteResizeSheet: View {
  @ObservedObject var model: NativeRemoteResizeDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:18) {
      Text(String(localized:"settings.resize.resize.remote.desktop", defaultValue:"Resize Remote Desktop")).font(.title2).bold()
      Text(String(localized:"settings.resize.request.a.new.resolution.from.the.server.this.may.affect.other.viewers", defaultValue:"Request a new resolution from the server. This may affect other viewers connected to the same desktop."))
        .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if model.displaySnapshot != nil {
            Text(String(localized:"settings.resize.resolution.from", defaultValue:"Resolution from")).fixedSize(horizontal: false, vertical: true)
            Picker(String(localized:"settings.resize.resolution.from", defaultValue:"Resolution from"),selection:$model.source) {
              ForEach(NativeRemoteResizeSource.allCases,id:\.self) { Text($0.title).tag($0) }
            }.labelsHidden().disabled(model.isBusy).accessibilityIdentifier("remoteResize.source")
          }
          if model.source == .custom {
            VStack(alignment: .leading, spacing: 8) {
              Text(String(localized:"settings.resize.width.in.pixels", defaultValue:"Width in pixels")).fixedSize(horizontal: false, vertical: true)
              TextField("",text:$model.width).accessibilityLabel(String(localized:"settings.resize.width.in.pixels", defaultValue:"Width in pixels")).accessibilityIdentifier("remoteResize.width")
              Text(String(localized:"settings.resize.height.in.pixels", defaultValue:"Height in pixels")).fixedSize(horizontal: false, vertical: true)
              TextField("",text:$model.height).accessibilityLabel(String(localized:"settings.resize.height.in.pixels", defaultValue:"Height in pixels")).accessibilityIdentifier("remoteResize.height")
            }.textFieldStyle(.roundedBorder).disabled(model.isBusy)
            Text(String(localized:"settings.resize.enter.whole.numbers.from.1.to.65535.the.server.and.this.connection", defaultValue:"Enter whole numbers from 1 to 65535. The server and this connection’s memory limit determine which sizes are accepted."))
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let baseline = model.baseline, baseline.layout.screens.count > 1 {
              Text(String(localized:"settings.resize.replaces.layout", defaultValue:"This request replaces the server’s current \((baseline.layout.screens.count).formatted())-screen layout with one screen."))
                .foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
            }
          } else {
            RemoteDisplayChooser(model:model).disabled(model.isBusy)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 100, idealHeight: 410, maxHeight: 410)
      if model.isBusy { ProgressView(String(localized:"settings.resize.waiting.for.the.server", defaultValue:"Waiting for the server…")).controlSize(.small) }
      if let message = model.message {
        Text(message).foregroundStyle(model.didApply ? Color.secondary : Color.orange)
          .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("remoteResize.result")
      }
      HStack {
        Button(String(localized:"trust.library.ui.reload", defaultValue:"Reload")) { model.reload() }.disabled(!model.canReload)
        Spacer()
        Button(model.didApply ? String(localized:"action.done", defaultValue:"Done") : String(localized:"action.cancel", defaultValue:"Cancel"),role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(String(localized:"settings.resize.resize", defaultValue:"Resize")) { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
      }
      if model.isBusy {
        Text(String(localized:"settings.resize.closing.this.sheet.cannot.undo.a.request.already.sent.to.the.server", defaultValue:"Closing this sheet cannot undo a request already sent to the server."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      }
    }.padding(24).frame(width:520).frame(maxHeight:680)
  }
}


private struct RemoteDisplayChooser: View {
  @ObservedObject var model: NativeRemoteResizeDraft
  private var displays: [NativeDisplay] { model.displaySnapshot?.displays ?? [] }
  private var bounds: CGRect {
    displays.reduce(CGRect.null) { $0.union(CGRect(x:$1.bounds.x,y:$1.bounds.y,width:$1.bounds.width,height:$1.bounds.height)) }
  }
  private func selection(_ id: NativeDisplayID) -> Binding<Bool> {
    Binding(get:{ model.selectedDisplays.contains(id) },set:{ value in
      if value { model.selectedDisplays.insert(id) } else { model.selectedDisplays.remove(id) }
    })
  }
  private func tile(index: Int, display: NativeDisplay, size: CGSize) -> some View {
    let extent = bounds
    let scale = min((Double(size.width)-12)/max(1,Double(extent.width)),
                    (Double(size.height)-12)/max(1,Double(extent.height)))
    let x = (Double(size.width)-Double(extent.width)*scale)/2 + (display.bounds.x-Double(extent.minX)+display.bounds.width/2)*scale
    let y = (Double(size.height)-Double(extent.height)*scale)/2 + (display.bounds.y-Double(extent.minY)+display.bounds.height/2)*scale
    let chosen = model.source == .allDisplays || model.selectedDisplays.contains(display.id)
    let color: Color = chosen ? .accentColor : .secondary
    return RoundedRectangle(cornerRadius:5).fill(color.opacity(0.18))
      .overlay(RoundedRectangle(cornerRadius:5).stroke(color,lineWidth:2))
      .overlay(Text(String(index+1)).font(.caption).bold())
      .frame(width:CGFloat(max(1,display.bounds.width*scale-3)),height:CGFloat(max(1,display.bounds.height*scale-3)))
      .position(x:CGFloat(x),y:CGFloat(y))
      .onTapGesture {
        guard model.source == .selectedDisplays, !model.isBusy else { return }
        let binding = selection(display.id); binding.wrappedValue.toggle()
      }
  }
  var body: some View {
    VStack(alignment:.leading,spacing:10) {
      if !displays.isEmpty && bounds.width.isFinite && bounds.height.isFinite {
        GeometryReader { geometry in
          ForEach(Array(displays.enumerated()),id:\.element.id) { index, display in
            tile(index:index,display:display,size:geometry.size)
          }
        }.frame(height:110)
          .environment(\.layoutDirection, .leftToRight).accessibilityHidden(true)
      }
      VStack(alignment:.leading,spacing:6) {
        ForEach(Array(displays.enumerated()),id:\.element.id) { index, display in
          let label = String(localized:"settings.display.description", defaultValue:"\((index+1).formatted()). \(display.name) — \(display.bounds.width.formatted(.number.precision(.fractionLength(0)))) × \(display.bounds.height.formatted(.number.precision(.fractionLength(0)))) points, \(display.backingScale.formatted())×")
          if model.source == .selectedDisplays {
            Toggle(label,isOn:selection(display.id)).toggleStyle(.checkbox)
          } else { Text(label) }
        }
        ForEach(Array(model.missingDisplays.enumerated()),id:\.element) { index, id in
          Toggle(String(localized:"settings.display.disconnected.selection", defaultValue:"Disconnected selected display \((index+1).formatted())"),isOn:selection(id)).toggleStyle(.checkbox)
        }
      }.frame(maxWidth:.infinity,alignment:.leading)
      Toggle(String(localized:"settings.resize.use.device.pixels", defaultValue:"Use device pixels"),isOn:$model.devicePixels)
      Text(String(localized:"settings.resize.creates.one.remote.screen.per.selected.local.display.this.changes.the.server", defaultValue:"Creates one remote screen per selected local display. This changes the server layout; it does not move or fullscreen this window."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      if let layout = model.displayLayout {
        Text(String(localized:"settings.resize.requested.layout", defaultValue:"Requested: \((layout.width).formatted()) × \((layout.height).formatted()) pixels · Screens: \((layout.regions.count).formatted())"))
        if layout.normalized {
          Text(String(localized:"settings.resize.the.remote.arrangement.is.adjusted.to.keep.displays.with.different.pixel.densities", defaultValue:"The remote arrangement is adjusted to keep displays with different pixel densities from overlapping."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
      }
      if let message = model.displayMessage {
        Text(message).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
      }
    }
  }
}
