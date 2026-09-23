// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct ConnectionSettingsFields: View {
  @Binding var shared: Bool?
  @Binding var reconnectOnError: Bool?
  let inheritedShared: Bool, inheritedReconnectOnError: Bool
  let inheritance: String
  var body: some View {
    VStack(alignment:.leading,spacing:14) {
      field(String(localized:"settings.connection.share.server.with.other.viewers", defaultValue:"Share server with other viewers"),value:$shared,inherited:inheritedShared,id:"shared")
      Text(String(localized:"settings.connection.requests.shared.access.when.connecting.with.sharing.off.the.server.may.disconnect", defaultValue:"Requests shared access when connecting. With sharing off, the server may disconnect other viewers. The server’s policy determines the result."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      field(String(localized:"settings.connection.offer.retry.after.connection.errors", defaultValue:"Offer Retry after connection errors"),value:$reconnectOnError,inherited:inheritedReconnectOnError,id:"retry")
      Text(String(localized:"settings.connection.shows.a.retry.action.for.recoverable.connection.errors.tidyvnc.reconnects.only.when", defaultValue:"Shows a Retry action for recoverable connection errors. TidyVNC reconnects only when you choose Retry or Connect."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }
  }
  private func field(_ title: String,value: Binding<Bool?>,inherited: Bool,id: String) -> some View {
    VStack(alignment:.leading,spacing:6) {
      Text(title).fixedSize(horizontal: false, vertical: true)
      Picker(title,selection:Binding(get: { value.wrappedValue.map { $0 ? 1 : 0 } ?? -1 },set: { value.wrappedValue = $0 == -1 ? nil : $0 == 1 })) {
        Text(inheritance).tag(-1)
        Text(String(localized:"settings.input.on", defaultValue:"On")).tag(1); Text(String(localized:"settings.input.off", defaultValue:"Off")).tag(0)
      }.labelsHidden().accessibilityIdentifier("connection.options.\(id)")
      if value.wrappedValue == nil {
        Text(String(localized:"settings.inheritance.effective.value", defaultValue:"Effective value: \(inherited ? String(localized:"settings.input.on", defaultValue:"On") : String(localized:"settings.input.off", defaultValue:"Off"))"))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
struct SessionConnectionSheet: View {
  @ObservedObject var model: NativeConnectionDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:14) {
      Text(String(localized:"settings.connection.connection.options", defaultValue:"Connection Options")).font(.title2)
      Text(String(localized:"settings.connection.apply.while.disconnected.then.connect.again.these.options.stay.in.this.window", defaultValue:"Apply while disconnected, then connect again. These options stay in this window; saved defaults and profiles remain unchanged."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      ConnectionSettingsFields(shared:$model.shared,reconnectOnError:$model.reconnectOnError,
        inheritedShared:model.initialShared,inheritedReconnectOnError:model.initialReconnectOnError,inheritance:String(localized:"settings.connection.initial.setting", defaultValue:"Initial setting"))
        .disabled(model.needsReload)
      if let baseline = model.baseline {
        Text(String(localized:"settings.connection.sources", defaultValue:"Shared access: \(source(baseline.sharedSource)) · Retry: \(source(baseline.reconnectSource))"))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.error { Text(error).foregroundStyle(Color.nativeErrorText).fixedSize(horizontal:false,vertical:true) }
      if model.didApply { Text(String(localized:"settings.connection.applied.to.this.connection.window", defaultValue:"Applied to this connection window.")).font(.caption).foregroundStyle(.secondary) }
      if model.needsReload { Button(String(localized:"action.discard.edits.reload", defaultValue:"Discard Edits and Reload")) { model.reload() }.disabled(!model.canReload) }
      HStack {
        Spacer()
        Button(model.hasChanges ? String(localized:"action.cancel", defaultValue:"Cancel") : String(localized:"action.done", defaultValue:"Done")) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        Button(String(localized:"action.apply", defaultValue:"Apply")) { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width:590)
  }
  private func source(_ value: NativeOptionSource) -> String {
    switch value { case .compiled: String(localized:"settings.connection.built.in.default", defaultValue:"built-in default"); case .appDefaults: String(localized:"settings.connection.app.default", defaultValue:"app default"); case .profile: String(localized:"settings.connection.profile", defaultValue:"profile"); case .session: String(localized:"settings.connection.connection.override", defaultValue:"connection override"); case .document: String(localized:"settings.connection.connection.file", defaultValue:"connection file"); case .commandLine: String(localized:"settings.connection.command.line", defaultValue:"command line") }
  }
}
