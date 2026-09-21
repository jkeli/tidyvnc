// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct RemoteResizePolicySheet: View {
  @ObservedObject var model: NativeRemoteResizePolicyDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:18) {
      Text("Remote Resize Settings").font(.title2).bold()
      Text("These settings apply to this connection window. Saved defaults and profiles stay unchanged.")
        .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      Toggle("Resize the remote desktop with this window",isOn:$model.enabled)
        .accessibilityIdentifier("remoteResizePolicy.enabled")
      Text(resizeSourceLabel(model.source(.enabled))).font(.caption).foregroundStyle(.secondary)
      Text("Automatic resizing follows the window or the complete fullscreen display arrangement in Unscaled mode. Device-pixel units include the display’s backing scale. View-only mode and servers without resize support prevent requests.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      VStack(alignment:.leading,spacing:6) {
        Text("Initial size for the next connection").font(.caption)
        TextField("Leave blank to use the server’s size",text:$model.initialSize).textFieldStyle(.roundedBorder)
          .accessibilityLabel("Initial desktop size").accessibilityIdentifier("remoteResizePolicy.initialSize")
        Text(resizeSourceLabel(model.source(.initialSize))).font(.caption).foregroundStyle(.secondary)
      }
      Text("Optional width × height in remote pixels, such as 1920x1080. Leave blank to use the server’s size. An initial size is requested once on the next connection when resizing is enabled, even in a scaled mode.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      Text("A resize may affect other viewers. Windowed and initial-size requests use one remote screen; fullscreen follows the selected displays. Turning resizing off cannot undo a request already sent.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      if let message = model.message ?? model.validationMessage { Text(message).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
      HStack {
        Button("Restore Initial Settings") { model.restoreInitial() }
        Spacer()
        Button("Cancel",role:.cancel) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        Button("Apply") { if model.apply() { dismiss() } }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width:560)
  }
}
