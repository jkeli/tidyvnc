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
      field("Share server with other viewers",value:$shared,inherited:inheritedShared,id:"shared")
      Text("Requests shared access when connecting. With sharing off, the server may disconnect other viewers. The server’s policy determines the result.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      field("Offer Retry after connection errors",value:$reconnectOnError,inherited:inheritedReconnectOnError,id:"retry")
      Text("Shows a Retry action for recoverable connection errors. TidyVNC reconnects only when you choose Retry or Connect.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }
  }
  private func field(_ title: String,value: Binding<Bool?>,inherited: Bool,id: String) -> some View {
    VStack(alignment:.leading,spacing:6) {
      Picker(title,selection:Binding(get: { value.wrappedValue.map { $0 ? 1 : 0 } ?? -1 },set: { value.wrappedValue = $0 == -1 ? nil : $0 == 1 })) {
        Text("\(inheritance) (\(inherited ? "On" : "Off"))").tag(-1)
        Text("On").tag(1); Text("Off").tag(0)
      }.accessibilityIdentifier("connection.options.\(id)")
    }
  }
}
struct SessionConnectionSheet: View {
  @ObservedObject var model: NativeConnectionDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:14) {
      Text("Connection Options").font(.title2)
      Text("Apply while disconnected, then connect again. These options stay in this window; saved defaults and profiles remain unchanged.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      ConnectionSettingsFields(shared:$model.shared,reconnectOnError:$model.reconnectOnError,
        inheritedShared:model.initialShared,inheritedReconnectOnError:model.initialReconnectOnError,inheritance:"Initial setting")
        .disabled(model.needsReload)
      if let baseline = model.baseline {
        Text("Shared access: \(source(baseline.sharedSource)) · Retry: \(source(baseline.reconnectSource))")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.error { Text(error).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
      if model.didApply { Text("Applied to this connection window.").font(.caption).foregroundStyle(.secondary) }
      HStack {
        if model.needsReload { Button("Discard Edits and Reload") { model.reload() }.disabled(!model.canReload) }
        Spacer()
        Button(model.hasChanges ? "Cancel" : "Done") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        Button("Apply") { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width:590)
  }
  private func source(_ value: NativeOptionSource) -> String {
    switch value { case .compiled: "built-in default"; case .appDefaults: "app default"; case .profile: "profile"; case .session: "connection override"; case .document: "connection file"; case .commandLine: "command line" }
  }
}
