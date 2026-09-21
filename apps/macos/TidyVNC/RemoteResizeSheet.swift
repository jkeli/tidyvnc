// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct RemoteResizeSheet: View {
  @ObservedObject var model: NativeRemoteResizeDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:18) {
      Text("Resize Remote Desktop").font(.title2).bold()
      Text("Request a new resolution from the server. This may affect other viewers connected to the same desktop.")
        .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      if model.displaySnapshot != nil {
        Picker("Resolution from",selection:$model.source) {
          ForEach(NativeRemoteResizeSource.allCases,id:\.self) { Text($0.title).tag($0) }
        }.disabled(model.isBusy).accessibilityIdentifier("remoteResize.source")
      }
      if model.source == .custom {
        Form {
          TextField("Width in pixels",text:$model.width).accessibilityIdentifier("remoteResize.width")
          TextField("Height in pixels",text:$model.height).accessibilityIdentifier("remoteResize.height")
        }.textFieldStyle(.roundedBorder).disabled(model.isBusy)
        Text("Enter whole numbers from 1 to 65535. The server and this connection’s memory limit determine which sizes are accepted.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        if let baseline = model.baseline, baseline.layout.screens.count > 1 {
          Text("This request replaces the server’s current \(baseline.layout.screens.count)-screen layout with one screen.")
            .foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
        }
      } else {
        RemoteDisplayChooser(model:model).disabled(model.isBusy)
      }
      if model.isBusy { ProgressView("Waiting for the server…").controlSize(.small) }
      if let message = model.message {
        Text(message).foregroundStyle(model.didApply ? Color.secondary : Color.orange)
          .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("remoteResize.result")
      }
      HStack {
        Button("Reload") { model.reload() }.disabled(!model.canReload)
        Spacer()
        Button(model.didApply ? "Done" : "Cancel",role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Resize") { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
      }
      if model.isBusy {
        Text("Closing this sheet cannot undo a request already sent to the server.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      }
    }.padding(24).frame(width:520)
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
        }.frame(height:110).accessibilityHidden(true)
      }
      ScrollView {
        VStack(alignment:.leading,spacing:6) {
          ForEach(Array(displays.enumerated()),id:\.element.id) { index, display in
            let label = "\(index+1). \(display.name) — \(display.bounds.width.formatted(.number.precision(.fractionLength(0)))) × \(display.bounds.height.formatted(.number.precision(.fractionLength(0)))) points, \(display.backingScale.formatted())×"
            if model.source == .selectedDisplays {
              Toggle(label,isOn:selection(display.id)).toggleStyle(.checkbox)
            } else { Text(label) }
          }
          ForEach(Array(model.missingDisplays.enumerated()),id:\.element) { index, id in
            Toggle("Disconnected selected display \(index+1)",isOn:selection(id)).toggleStyle(.checkbox)
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.frame(height:min(100,CGFloat(displays.count+model.missingDisplays.count)*26))
      Toggle("Use device pixels",isOn:$model.devicePixels)
      Text("Creates one remote screen per selected local display. This changes the server layout; it does not move or fullscreen this window.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      if let layout = model.displayLayout {
        Text("Requested: \(layout.width) × \(layout.height) pixels, \(layout.regions.count) screens.")
        if layout.normalized {
          Text("The remote arrangement is adjusted to keep displays with different pixel densities from overlapping.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
      }
      if let message = model.displayMessage {
        Text(message).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
      }
    }
  }
}
