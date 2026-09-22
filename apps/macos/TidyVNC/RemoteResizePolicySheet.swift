// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct RemoteResizePolicySheet: View {
  @ObservedObject var model: NativeRemoteResizePolicyDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:18) {
      Text(String(localized:"settings.resize.remote.resize.settings", defaultValue:"Remote Resize Settings")).font(.title2).bold()
      Text(String(localized:"settings.resize.these.settings.apply.to.this.connection.window.saved.defaults.and.profiles.stay", defaultValue:"These settings apply to this connection window. Saved defaults and profiles stay unchanged."))
        .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Toggle(String(localized:"settings.resize.resize.the.remote.desktop.with.this.window", defaultValue:"Resize the remote desktop with this window"),isOn:$model.enabled)
            .accessibilityIdentifier("remoteResizePolicy.enabled")
          Text(resizeSourceLabel(model.source(.enabled))).font(.caption).foregroundStyle(.secondary)
          Text(String(localized:"settings.resize.automatic.resizing.follows.the.window.or.the.complete.fullscreen.display.arrangement.in", defaultValue:"Automatic resizing follows the window or the complete fullscreen display arrangement in Unscaled mode. Device-pixel units include the display’s backing scale. View-only mode and servers without resize support prevent requests."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
          VStack(alignment:.leading,spacing:6) {
            Text(String(localized:"settings.resize.initial.size.for.the.next.connection", defaultValue:"Initial size for the next connection")).font(.caption)
            Text(String(localized:"settings.resize.leave.blank.to.use.the.server.s.size", defaultValue:"Leave blank to use the server’s size")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("",text:$model.initialSize).textFieldStyle(.roundedBorder)
              .accessibilityLabel(String(localized:"settings.resize.initial.desktop.size", defaultValue:"Initial desktop size")).accessibilityIdentifier("remoteResizePolicy.initialSize")
            Text(resizeSourceLabel(model.source(.initialSize))).font(.caption).foregroundStyle(.secondary)
          }
          Text(String(localized:"settings.resize.optional.width.height.in.remote.pixels.such.as.1920x1080.leave.blank.to", defaultValue:"Optional width × height in remote pixels, such as 1920x1080. Leave blank to use the server’s size. An initial size is requested once on the next connection when resizing is enabled, even in a scaled mode."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
          Text(String(localized:"settings.resize.a.resize.may.affect.other.viewers.windowed.and.initial.size.requests.use", defaultValue:"A resize may affect other viewers. Windowed and initial-size requests use one remote screen; fullscreen follows the selected displays. Turning resizing off cannot undo a request already sent."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 100, idealHeight: 430, maxHeight: 430)
      if let message = model.message ?? model.validationMessage { Text(message).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
      Button(String(localized:"settings.fullscreen.restore.initial.settings", defaultValue:"Restore Initial Settings")) { model.restoreInitial() }
      HStack {
        Spacer()
        Button(String(localized:"action.cancel", defaultValue:"Cancel"),role:.cancel) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        Button(String(localized:"action.apply", defaultValue:"Apply")) { if model.apply() { dismiss() } }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width:560).frame(maxHeight:680)
  }
}
